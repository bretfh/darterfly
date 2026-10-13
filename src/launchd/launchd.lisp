(defpackage #:finch/launchd
  (:use #:cl)
  (:local-nicknames (#:bsd #:finch/bsd) (#:mach #:finch/mach) (#:plist #:finch/plist))
  (:export #:bootstrap-check-in #:bootstrap-look-up #:bootstrap-port #:launchd-call
           #:+bootstrap-unknown-service+ #:+bootstrap-not-privileged+ #:+bootstrap-service-active+))
(in-package #:finch/launchd)

(defconstant +bootstrap-not-privileged+ 1100)
(defconstant +bootstrap-unknown-service+ 1102)
(defconstant +bootstrap-service-active+ 1103)
(defconstant +mach-notify-port-destroyed+ #o105)

(defparameter *daemons* '("/System/Library/LaunchDaemons" "/Library/LaunchDaemons"))

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
(defvar *lock* (sb-thread:make-mutex :name "launchd"))
(defvar *notify* nil)

(defun key (plist name &optional default)
  (multiple-value-bind (value found) (gethash name plist)
    (if found value default)))

(defun log-line (control &rest args)
  (format *standard-output* "launchd: ~?~%" control args)
  (finish-output *standard-output*))

(defun load-job (plist)
  (let* ((label (key plist "Label"))
         (arguments (coerce (key plist "ProgramArguments" #()) 'list))
         (program (or (key plist "Program") (first arguments))))
    (when (and label program (not (key plist "Disabled")))
      (let ((job (make-instance 'job :label label :program program
                                     :arguments (or arguments (list program)) :plist plist)))
        (handler-case (bsd:stat program)
          (bsd:errno (e) (setf (unavailable job) (bsd:errno-name e))))
        (let ((machservices (key plist "MachServices")))
          (when (hash-table-p machservices)
            (loop :for name :being :the :hash-keys :of machservices
                  :do (let* ((options (gethash name machservices))
                             (service (make-instance 'service :name name :job job
                                                              :hidden (and (hash-table-p options)
                                                                           (key options "HideUntilCheckIn"))
                                                              :port (mach:mach-port-allocate mach:*task* :receive))))
                        (push service (services job))
                        (setf (gethash name *services*) service)))))
        job))))

(defun load-jobs ()
  (loop :for dir :in *daemons*
        :append (loop :for file :in (sort (handler-case (bsd:readdir dir) (bsd:errno () nil)) #'string<)
                      :when (uiop:string-suffix-p file ".plist")
                        :append (handler-case
                                    (let ((job (load-job (plist:read-plist (bsd::path (format nil "~a/~a" dir file))))))
                                      (and job (list job)))
                                  (error (e) (log-line "~a/~a: ~a" dir file e) nil)))))

(defun keep-alive-p (job)
  (let ((keep (key (job-plist job) "KeepAlive")))
    (and keep (not (eq keep :false)))))

(defun environment (job)
  (let ((env (key (job-plist job) "EnvironmentVariables")))
    (append (list "PATH=/usr/bin:/bin:/usr/sbin:/sbin")
            (and (hash-table-p env)
                 (loop :for k :being :the :hash-keys :of env :using (hash-value v)
                       :collect (format nil "~a=~a" k v))))))

(defun file-actions (job)
  (flet ((std (fd key flags)
           (list :open fd (key (job-plist job) key "/dev/null") flags)))
    (list (std 0 "StandardInPath" bsd:+o-rdonly+)
          (std 1 "StandardOutPath" (logior bsd:+o-wronly+ bsd:+o-creat+ bsd:+o-append+))
          (std 2 "StandardErrorPath" (logior bsd:+o-wronly+ bsd:+o-creat+ bsd:+o-append+)))))

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
  (let ((interval (key (job-plist job) "ThrottleInterval" 10))
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
      (bsd:errno () (sleep 0.1)))))

(defun reply (message body &optional descriptors)
  (when (mach:msgh-remote-port message)
    (mach:mach-msg-send (mach:make-message :remote-port (mach:msgh-remote-port message)
                                           :remote-disposition :move-send-once
                                           :body body :descriptors descriptors))))

(defun job-of-pid (pid)
  (find pid *jobs* :key #'pid))

(defun check-in (message name pid)
  (let ((service (gethash name *services*)))
    (cond ((null service) (reply message (list :kr +bootstrap-unknown-service+)))
          ((not (eq (job service) (job-of-pid pid))) (reply message (list :kr +bootstrap-not-privileged+)))
          ((active service) (reply message (list :kr +bootstrap-service-active+)))
          (t
           (let ((port (port service)))
             (unless (send service)
               (mach:mach-port-insert-right mach:*task* port port :make-send)
               (setf (send service) port))
             (mach:mach-port-request-notification mach:*task* port :port-destroyed 0 *notify* :make-send-once)
             (setf (active service) t
                   (hidden service) nil)
             (reply message (list :kr 0) (list (cons port :move-receive))))))))

(defun look-up (message name)
  (let ((service (gethash name *services*)))
    (if (or (null service) (hidden service))
        (reply message (list :kr +bootstrap-unknown-service+))
        (progn
          (start (job service))
          (reply message (list :kr 0)
                 (list (cons (port service) (if (send service) :copy-send :make-send))))))))

(defun list-jobs (message)
  (reply message (list :kr 0
                       :jobs (mapcar (lambda (job)
                                       (list (pid job)
                                             (let ((s (status job)))
                                               (cond ((null s) 0)
                                                     ((bsd:wifexited s) (bsd:wexitstatus s))
                                                     ((bsd:wifsignaled s) (- (bsd:wtermsig s)))
                                                     (t 0)))
                                             (label job)
                                             (unavailable job)))
                                     *jobs*))))

(defun returned (message)
  (let* ((carried (car (first (mach:msgh-descriptors message))))
         (service (find-if (lambda (s) (eql (port s) carried)) (all-services))))
    (when service
      (setf (active service) nil))))

(defun all-services ()
  (loop :for s :being :the :hash-values :of *services* :collect s))


(defun serve (bootstrap set)
  (loop
    (let ((message (mach:mach-msg-receive set)))
      (sb-thread:with-mutex (*lock*)
        (if (= (mach:msgh-id message) +mach-notify-port-destroyed+)
            (returned message)
            (destructuring-bind (&key routine name pid &allow-other-keys) (mach:msgh-body message)
              (case routine
                (:check-in (check-in message name pid))
                (:look-up (look-up message name))
                (:list (list-jobs message))
                (t (reply message (list :kr 1))))))))
    bootstrap))

(bsd:define-program "launchd" (argv envp)
  (let* ((bootstrap (mach:mach-port-allocate mach:*task* :receive))
         (set (mach:mach-port-allocate mach:*task* :port-set)))
    (mach:mach-port-insert-right mach:*task* bootstrap bootstrap :make-send)
    (mach:task-set-special-port mach:*task* :bootstrap bootstrap)
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
    (sb-thread:with-mutex (*lock*)
      (dolist (job *jobs*)
        (when (or (key (job-plist job) "RunAtLoad") (keep-alive-p job))
          (start job))))
    (serve bootstrap set)))

(defun bootstrap-port ()
  (mach:task-get-special-port mach:*task* :bootstrap))

(defun launchd-call (body &key (timeout 5000))
  (let ((reply (mach:mach-reply-port)))
    (unwind-protect
         (progn
           (mach:mach-msg-send (mach:make-message :remote-port (bootstrap-port) :local-port reply
                                                  :local-disposition :make-send-once :body body))
           (let ((message (mach:mach-msg-receive reply :timeout timeout)))
             (values (mach:msgh-body message) (mach:msgh-descriptors message))))
      (mach:mach-port-mod-refs mach:*task* reply :receive -1))))

(defun bootstrap-check-in (name)
  (multiple-value-bind (body descriptors)
      (launchd-call (list :routine :check-in :name name :pid (bsd:getpid)))
    (values (and (zerop (getf body :kr)) (car (first descriptors))) (getf body :kr))))

(defun bootstrap-look-up (name)
  (multiple-value-bind (body descriptors) (launchd-call (list :routine :look-up :name name))
    (values (and (zerop (getf body :kr)) (car (first descriptors))) (getf body :kr))))

(bsd:define-program "launchctl" (argv envp)
  (let ((command (second argv)))
    (cond ((equal command "list")
           (format t "PID~cStatus~cLabel~%" #\Tab #\Tab)
           (dolist (row (getf (launchd-call (list :routine :list)) :jobs))
             (destructuring-bind (pid status label unavailable) row
               (unless unavailable
                 (format t "~a~c~d~c~a~%" (or pid "-") #\Tab status #\Tab label))))
           0)
          (t (format *error-output* "usage: launchctl list~%") 64))))
