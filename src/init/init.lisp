(defpackage #:darterfly/init
  (:use #:cl)
  (:local-nicknames (#:bsd #:darterfly/bsd) (#:mach #:darterfly/mach))
  (:export #:bootstrap-check-in #:bootstrap-look-up #:bootstrap-port #:init-call #:launch))
(in-package #:darterfly/init)

(defconstant +mach-notify-port-destroyed+ #o105)

(defparameter *daemons* '("/System/Library/Jobs" "/Library/Jobs"))

(defclass job ()
  ((label :initarg :label :reader label)
   (program :initarg :program :reader program)
   (arguments :initarg :arguments :reader arguments)
   (plist :initarg :plist :reader job-plist)
   (pid :initform nil :accessor pid)
   (status :initform nil :accessor status)
   (started :initform 0 :accessor started)
   (unavailable :initform nil :accessor unavailable)
   (services :initform nil :accessor services)))

(defclass service ()
  ((name :initarg :name :reader name)
   (job :initarg :job :reader job)
   (port :initarg :port :accessor port)
   (send :initform nil :accessor send)
   (active :initform nil :accessor active)
   (hidden :initarg :hidden :initform nil :accessor hidden)))

(defvar *jobs* nil)
(defvar *services* (make-hash-table :test 'equal))
(defvar *lock* (sb-thread:make-mutex :name "init"))
(defvar *notify* nil)

(defun key (plist name &optional default)
  (getf plist name default))

(defun log-line (control &rest args)
  (format *standard-output* "init: ~?~%" control args)
  (finish-output *standard-output*))

(defun load-job (plist)
  (let* ((label (key plist :label))
         (arguments (key plist :arguments))
         (program (or (key plist :program) (first arguments))))
    (when (and label program (not (key plist :disabled)))
      (let ((job (make-instance 'job :label label :program program
                                     :arguments (or arguments (list program)) :plist plist)))
        (handler-case (bsd:stat program)
          (bsd:errno (e) (setf (unavailable job) (bsd:errno-name e))))
        (dolist (entry (key plist :services))
          (destructuring-bind (name &key hidden) (if (consp entry) entry (list entry))
            (let ((service (make-instance 'service :name name :job job :hidden hidden
                                                   :port (mach:mach-port-allocate mach:*task* :receive))))
              (push service (services job))
              (setf (gethash name *services*) service))))
        job))))

(defun read-job (path)
  (with-open-file (s (bsd::path path))
    (with-standard-io-syntax
      (let ((*read-eval* nil)) (read s)))))

(defun load-jobs ()
  (loop :for dir :in *daemons*
        :append (loop :for file :in (sort (handler-case (bsd:readdir dir) (bsd:errno () nil)) #'string<)
                      :when (uiop:string-suffix-p file ".job")
                        :append (handler-case
                                    (let ((job (load-job (read-job (format nil "~a/~a" dir file)))))
                                      (and job (list job)))
                                  (error (e) (log-line "~a/~a: ~a" dir file e) nil)))))

(defun keep-alive-p (job)
  (key (job-plist job) :keep-alive))

(defun start-at-load-p (job)
  (let ((keep (key (job-plist job) :keep-alive)))
    (or (key (job-plist job) :run-at-load)
        (and keep (not (eq keep :after-demand))))))

(defun environment (job)
  (append (list "PATH=/usr/bin:/bin:/usr/sbin:/sbin")
          (loop :for (k . v) :in (key (job-plist job) :environment)
                :collect (format nil "~a=~a" k v))))

(defun file-actions (job)
  (flet ((std (fd key flags)
           (list :open fd (key (job-plist job) key "/dev/null") flags)))
    (list (std 0 :stdin bsd:+o-rdonly+)
          (std 1 :stdout (logior bsd:+o-wronly+ bsd:+o-creat+ bsd:+o-append+))
          (std 2 :stderr (logior bsd:+o-wronly+ bsd:+o-creat+ bsd:+o-append+)))))

(defun start (job)
  (unless (or (pid job) (unavailable job))
    (handler-case
        (progn
          (setf (pid job) (bsd:posix-spawn (program job) (arguments job) (environment job)
                                           :file-actions (file-actions job))
                (started job) (get-internal-real-time)))
      (bsd:errno (e)
        (setf (unavailable job) (bsd:errno-name e))
        (log-line "~a: ~a" (label job) (bsd:errno-name e))))))

(defun throttle (job)
  (let ((interval (key (job-plist job) :throttle 10))
        (ran (/ (- (get-internal-real-time) (started job)) internal-time-units-per-second)))
    (max 0 (- interval ran))))

(defun reaped (pid status)
  (sb-thread:with-mutex (*lock*)
    (let ((job (find pid *jobs* :key #'pid)))
      (when job
        (setf (pid job) nil
              (status job) status)
        (when (keep-alive-p job)
          (let ((delay (throttle job)))
            (bsd:bsdthread-create (lambda ()
                                    (sleep delay)
                                    (sb-thread:with-mutex (*lock*) (start job)))
                                  "throttle")))))))

(defun reaper ()
  (loop
    (handler-case
        (multiple-value-bind (pid status) (bsd:wait4 -1)
          (reaped pid status))
      (bsd:errno () (sleep 0.1))
      (error (e) (format *error-output* "~&reaper: ~a~%" e) (sleep 0.1)))))

(defun reply (message body &optional descriptors)
  (when (mach:msgh-remote-port message)
    (mach:mach-msg-send (mach:make-message :remote-port (mach:msgh-remote-port message)
                                           :remote-disposition :move-send-once
                                           :body body :descriptors descriptors))))

(defun fail-reply (message code)
  (reply message (list :error code)))

(defun job-of-pid (pid)
  (find pid *jobs* :key #'pid))

(defun check-in (message name pid)
  (let ((service (gethash name *services*)))
    (cond ((null service) (fail-reply message :unknown-service))
          ((not (eq (job service) (job-of-pid pid))) (fail-reply message :not-privileged))
          ((active service) (fail-reply message :service-active))
          (t
           (let ((port (port service)))
             (unless (send service)
               (mach:mach-port-insert-right mach:*task* port port :make-send)
               (setf (send service) port))
             (mach:mach-port-request-notification mach:*task* port :port-destroyed 0 *notify* :make-send-once)
             (setf (active service) t
                   (hidden service) nil)
             (reply message (list :port t) (list (cons port :move-receive))))))))

(defun look-up (message name)
  (let ((service (gethash name *services*)))
    (if (or (null service) (hidden service))
        (fail-reply message :unknown-service)
        (progn
          (start (job service))
          (reply message (list :port t)
                 (list (cons (port service) (if (send service) :copy-send :make-send))))))))

(defun exit-code (status)
  (cond ((null status) 0)
        ((bsd:wifexited status) (bsd:wexitstatus status))
        ((bsd:wifsignaled status) (- (bsd:wtermsig status)))
        (t 0)))

(defun list-jobs (message)
  (reply message
         (list :jobs (mapcar (lambda (job)
                               (list :pid (or (pid job) 0) :status (exit-code (status job))
                                     :label (label job) :available (not (unavailable job))))
                             *jobs*))))

(defun returned (message)
  (let* ((carried (car (first (mach:msgh-descriptors message))))
         (service (find-if (lambda (s) (eql (port s) carried)) (all-services))))
    (when service
      (setf (active service) nil))))

(defun all-services ()
  (loop :for s :being :the :hash-values :of *services* :collect s))

(defun launch-job (message label)
  (let ((job (find label *jobs* :key #'label :test #'string=)))
    (cond ((null job) (fail-reply message :unknown-service))
          (t (start job)
             (if (unavailable job)
                 (fail-reply message :unavailable)
                 (reply message (list :pid (or (pid job) 0))))))))

(defun serve (bootstrap set)
  (loop
    (let ((message (mach:mach-msg-receive set)))
      (sb-thread:with-mutex (*lock*)
        (if (= (mach:msgh-id message) +mach-notify-port-destroyed+)
            (returned message)
            (let ((request (mach:msgh-body message)))
              (if (consp request)
                  (destructuring-bind (op &key name label &allow-other-keys) request
                    (case op
                      (:check-in (check-in message name (bsd:task-pid (mach:msgh-audit message))))
                      (:look-up (look-up message name))
                      (:list (list-jobs message))
                      (:launch (launch-job message label))
                      (t (fail-reply message :unknown-request))))
                  (fail-reply message :unknown-request))))))
    bootstrap))

(bsd:define-program "init" (argv envp)
  (let* ((bootstrap (mach:mach-port-allocate mach:*task* :receive))
         (set (mach:mach-port-allocate mach:*task* :port-set)))
    (mach:mach-port-insert-right mach:*task* bootstrap bootstrap :make-send)
    (mach:task-set-special-port mach:*task* :bootstrap bootstrap)
    (mach:task-set-special-port (bsd:proc-task bsd:*proc0*) :bootstrap bootstrap)
    (setf *notify* (mach:mach-port-allocate mach:*task* :receive))
    (mach:mach-port-move-member mach:*task* bootstrap set)
    (mach:mach-port-move-member mach:*task* *notify* set)
    (log-line "pid ~d, bootstrap port #x~x" (bsd:getpid) bootstrap)
    (sb-thread:with-mutex (*lock*)
      (setf *services* (make-hash-table :test 'equal)
            *jobs* (load-jobs))
      (log-line "~d jobs, ~d services, ~d unavailable"
                (length *jobs*) (hash-table-count *services*) (count-if #'unavailable *jobs*)))
    (bsd:bsdthread-create #'reaper "reaper")
    (sb-thread:make-thread #'darterfly/worlds:heartbeat :name "heartbeat")
    (sb-thread:make-thread (lambda () (sleep 2) (darterfly/run:restore-worlds)) :name "restore worlds")
    (sb-thread:with-mutex (*lock*)
      (dolist (job *jobs*)
        (when (start-at-load-p job)
          (start job))))
    (serve bootstrap set)))

(defun bootstrap-port ()
  (mach:task-get-special-port mach:*task* :bootstrap))

(defun init-call (request &key (timeout 5000))
  (let ((reply (mach:mach-reply-port)))
    (unwind-protect
         (progn
           (mach:mach-msg-send (mach:make-message :remote-port (bootstrap-port) :local-port reply
                                                  :local-disposition :make-send-once :body request))
           (let ((message (mach:mach-msg-receive reply :timeout timeout)))
             (values (mach:msgh-body message) (car (first (mach:msgh-descriptors message))))))
      (mach:mach-port-mod-refs mach:*task* reply :receive -1))))

(defun port-call (request)
  (multiple-value-bind (body port) (init-call request)
    (if (getf body :error)
        (values nil (getf body :error))
        (values port nil))))

(defun bootstrap-check-in (name)
  (port-call (list :check-in :name name)))

(defun bootstrap-look-up (name)
  (port-call (list :look-up :name name)))

(defun launch (label)
  (let ((reply (init-call (list :launch :label label))))
    (if (getf reply :error)
        (values nil (getf reply :error))
        (values (getf reply :pid) nil))))

(bsd:define-program "service" (argv envp)
  (let ((command (second argv)))
    (cond ((equal command "list")
           (format t "PID~cStatus~cLabel~%" #\Tab #\Tab)
           (dolist (job (getf (init-call (list :list)) :jobs))
             (when (getf job :available)
               (let ((pid (getf job :pid)))
                 (format t "~a~c~d~c~a~%" (if (zerop pid) "-" pid) #\Tab (getf job :status) #\Tab (getf job :label)))))
           0)
          ((equal command "start")
           (multiple-value-bind (pid code) (launch (third argv))
             (if pid (progn (format t "~a~%" pid) 0) (progn (format *error-output* "~a: ~(~a~)~%" (third argv) code) 1))))
          (t (format *error-output* "usage: service list | start label~%") 64))))

(defun forget-jobs ()
  (setf *lock* (sb-thread:make-mutex :name "init")
        *jobs* nil *services* (make-hash-table :test 'equal) *notify* nil))

(pushnew 'forget-jobs sb-ext:*save-hooks*)
