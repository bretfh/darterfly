(defpackage #:finch/launchd
  (:use #:cl)
  (:local-nicknames (#:bsd #:finch/bsd) (#:mach #:finch/mach) (#:plist #:finch/plist) (#:xpc #:finch/xpc))
  (:export #:bootstrap-check-in #:bootstrap-look-up #:bootstrap-port #:launchd-call #:kickstart
           #:+bootstrap-unknown-service+ #:+bootstrap-not-privileged+ #:+bootstrap-service-active+))
(in-package #:finch/launchd)

(defconstant +bootstrap-not-privileged+ 1100)
(defconstant +bootstrap-unknown-service+ 1102)
(defconstant +bootstrap-service-active+ 1103)
(defconstant +mach-notify-port-destroyed+ #o105)
(defconstant +routine-check-in+ #x400000ce)
(defconstant +routine-look-up+ #x400000cf)
(defconstant +routine-list+ #x40000fff)
(defconstant +routine-kickstart+ #x40000ffe)
(defconstant +reply+ #x20000000)

(defparameter *daemons* '("/System/Library/LaunchDaemons" "/Library/LaunchDaemons"
                          "/System/Library/LaunchAgents" "/Library/LaunchAgents"))

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

(defun start-at-load-p (job)
  (let ((keep (key (job-plist job) "KeepAlive")))
    (or (key (job-plist job) "RunAtLoad")
        (and keep (not (and (hash-table-p keep) (key keep "AfterInitialDemand")))))))

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

(defun reply (message entries &optional descriptors)
  (when (mach:msgh-remote-port message)
    (multiple-value-bind (octets rights)
        (xpc:encode (apply #'xpc:dictionary "rec_execcnt" (list :uint64 0)
                           "req_pid" (list :uint64 (bsd:getpid)) entries))
      (declare (ignore rights))
      (mach:mach-msg-send (mach:make-message :remote-port (mach:msgh-remote-port message)
                                             :remote-disposition :move-send-once :id +reply+
                                             :body octets :descriptors descriptors)))))

(defun fail-reply (message code)
  (reply message (list "error" (list :int64 code))))

(defun job-of-pid (pid)
  (find pid *jobs* :key #'pid))

(defun check-in (message name pid)
  (let ((service (gethash name *services*)))
    (cond ((null service) (fail-reply message +bootstrap-unknown-service+))
          ((not (eq (job service) (job-of-pid pid))) (fail-reply message +bootstrap-not-privileged+))
          ((active service) (fail-reply message +bootstrap-service-active+))
          (t
           (let ((port (port service)))
             (unless (send service)
               (mach:mach-port-insert-right mach:*task* port port :make-send)
               (setf (send service) port))
             (mach:mach-port-request-notification mach:*task* port :port-destroyed 0 *notify* :make-send-once)
             (setf (active service) t
                   (hidden service) nil)
             (reply message (list "port" (list :receive port)) (list (cons port :move-receive))))))))

(defun look-up (message name)
  (let ((service (gethash name *services*)))
    (if (or (null service) (hidden service))
        (fail-reply message +bootstrap-unknown-service+)
        (progn
          (start (job service))
          (reply message (list "port" (list :send (port service)))
                 (list (cons (port service) (if (send service) :copy-send :make-send))))))))

(defun list-jobs (message)
  (reply message
         (list "jobs" (cons :array
                            (mapcar (lambda (job)
                                      (xpc:dictionary
                                       "pid" (list :int64 (or (pid job) 0))
                                       "status" (list :int64 (let ((s (status job)))
                                                               (cond ((null s) 0)
                                                                     ((bsd:wifexited s) (bsd:wexitstatus s))
                                                                     ((bsd:wifsignaled s) (- (bsd:wtermsig s)))
                                                                     (t 0))))
                                       "label" (label job)
                                       "available" (list :bool (not (unavailable job)))))
                                    *jobs*)))))

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
            (let* ((request (handler-case (xpc:decode (mach:msgh-body message)
                                                      (mapcar #'car (mach:msgh-descriptors message)))
                              (error () nil)))
                   (name (and request (xpc:value request "name"))))
              (cond ((null request) (fail-reply message 22))
                    ((= (mach:msgh-id message) +routine-check-in+)
                     (check-in message name (bsd:task-pid (mach:msgh-audit message))))
                    ((= (mach:msgh-id message) +routine-look-up+) (look-up message name))
                    ((= (mach:msgh-id message) +routine-list+) (list-jobs message))
                    ((= (mach:msgh-id message) +routine-kickstart+)
                     (let ((job (find (xpc:value request "label") *jobs* :key #'label :test #'string=)))
                       (cond ((null job) (fail-reply message +bootstrap-unknown-service+))
                             (t (start job)
                                (if (unavailable job)
                                    (fail-reply message 2)
                                    (reply message (list "pid" (list :int64 (or (pid job) 0)))))))))
                    (t (fail-reply message 78)))))))
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
        (when (start-at-load-p job)
          (start job))))
    (serve bootstrap set)))

(defun bootstrap-port ()
  (mach:task-get-special-port mach:*task* :bootstrap))

(defun launchd-call (routine entries &key (timeout 5000))
  (let ((reply (mach:mach-reply-port))
        (domain (bootstrap-port)))
    (unwind-protect
         (multiple-value-bind (octets rights)
             (xpc:encode (apply #'xpc:dictionary (append entries (list "domain-port" (list :send domain)))))
           (mach:mach-msg-send (mach:make-message :remote-port domain :local-port reply
                                                  :local-disposition :make-send-once :id routine :body octets
                                                  :descriptors (mapcar (lambda (r) (cons (car r) :copy-send)) rights)))
           (let ((message (mach:mach-msg-receive reply :timeout timeout)))
             (xpc:decode (mach:msgh-body message) (mapcar #'car (mach:msgh-descriptors message)))))
      (mach:mach-port-mod-refs mach:*task* reply :receive -1))))

(defun result (reply)
  (let ((error (xpc:value reply "error")))
    (if error
        (values nil (second error))
        (values (second (xpc:value reply "port")) 0))))

(defun bootstrap-check-in (name)
  (result (launchd-call +routine-check-in+
                        (list "handle" (list :uint64 0) "flags" (list :uint64 0) "name" name
                              "type" (list :uint64 7)))))

(defun kickstart (label)
  (let ((reply (launchd-call +routine-kickstart+ (list "label" label))))
    (if (xpc:value reply "error")
        (values nil (second (xpc:value reply "error")))
        (values (second (xpc:value reply "pid")) 0))))

(defun bootstrap-look-up (name)
  (result (launchd-call +routine-look-up+
                        (list "handle" (list :uint64 0) "instance" (list :uuid (make-array 16 :element-type '(unsigned-byte 8) :initial-element 0))
                              "flags" (list :uint64 0) "name" name "type" (list :uint64 7)
                              "targetpid" (list :int64 0)))))

(bsd:define-program "launchctl" (argv envp)
  (let ((command (second argv)))
    (cond ((equal command "list")
           (format t "PID~cStatus~cLabel~%" #\Tab #\Tab)
           (dolist (job (rest (xpc:value (launchd-call +routine-list+ nil) "jobs")))
             (when (second (xpc:value job "available"))
               (let ((pid (second (xpc:value job "pid"))))
                 (format t "~a~c~d~c~a~%" (if (zerop pid) "-" pid) #\Tab
                         (second (xpc:value job "status")) #\Tab (xpc:value job "label")))))
           0)
          ((equal command "kickstart")
           (multiple-value-bind (pid code) (kickstart (third argv))
             (if pid (progn (format t "~a~%" pid) 0) (progn (format *error-output* "~a: ~a~%" (third argv) code) 1))))
          (t (format *error-output* "usage: launchctl list | kickstart label~%") 64))))
