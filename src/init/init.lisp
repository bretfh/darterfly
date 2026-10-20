(defpackage #:darterfly/init
  (:use #:cl)
  (:local-nicknames (#:bsd #:darterfly/bsd) (#:mach #:darterfly/mach))
  (:export #:bootstrap-check-in #:bootstrap-look-up #:bootstrap-port #:init-call #:launch
           #:job #:decide #:submit #:remove-job #:release #:jobs #:inspect-job #:*sample-every*))
(in-package #:darterfly/init)

(defconstant +mach-notify-port-destroyed+ #o105)

(defparameter *daemons* '("/System/Library/Jobs" "/Library/Jobs"))
(defparameter *sample-every* 2)

(defclass job ()
  ((label :initarg :label :reader label)
   (program :initarg :program :reader program)
   (arguments :initarg :arguments :reader arguments)
   (plist :initarg :plist :reader job-plist)
   (pid :initform nil :accessor pid)
   (status :initform nil :accessor status)
   (started :initform 0 :accessor started)
   (unavailable :initform nil :accessor unavailable)
   (services :initform nil :accessor services)
   (world :initform nil :accessor world)
   (watcher :initform nil :accessor watcher)
   (state :initform nil :accessor state)
   (reason :initform nil :accessor reason)
   (exits :initform nil :accessor exits)
   (cpu :initform nil :accessor cpu)
   (removing :initform nil :accessor removing)
   (checked-at :initform 0 :accessor checked-at)
   (unhealthy-since :initform nil :accessor unhealthy-since)))

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
    (when (and label (or program (key plist :world)) (not (key plist :disabled)))
      (let ((job (make-instance 'job :label label :program program
                                     :arguments (or arguments (list program)) :plist plist)))
        (when program
          (handler-case (bsd:stat program)
            (bsd:errno (e) (setf (unavailable job) (bsd:errno-name e)))))
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

(defun world-spec (job)
  (let ((world (key (job-plist job) :world)))
    (if (listp world) world nil)))

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
  (if (key (job-plist job) :world)
      (start-in-world job)
      (spawn job)))

(defun spawn (job)
  (unless (or (pid job) (unavailable job))
    (handler-case
        (progn
          (setf (pid job) (bsd:posix-spawn (program job) (arguments job) (environment job)
                                           :file-actions (file-actions job))
                (started job) (get-internal-real-time)))
      (bsd:errno (e)
        (setf (unavailable job) (bsd:errno-name e))
        (log-line "~a: ~a" (label job) (bsd:errno-name e))))))

(defun recent-exits (job)
  (let ((since (- (get-universal-time) (key (job-plist job) :window 60))))
    (remove-if (lambda (exit) (< (getf exit :time) since))
               (exits job))))

(defun throttle (job)
  (let ((interval (key (job-plist job) :throttle 10))
        (ran (/ (- (get-internal-real-time) (started job)) internal-time-units-per-second)))
    (max 0 (- interval ran))))

(defun note (job state reason)
  (setf (state job) state
        (reason job) reason)
  (log-line "~a ~(~a~)~@[: ~a~]" (label job) state reason))

(defgeneric decide (job kind detail))

(defmethod decide ((job job) (kind (eql :exit)) detail)
  (let ((keep (keep-alive-p job))
        (failed (not (eql 0 (getf detail :exit))))
        (recent (length (recent-exits job)))
        (most (key (job-plist job) :most-exits)))
    (cond ((removing job)
           (values :leave "removed"))
          ((not keep)
           (values :leave "not kept alive"))
          ((and (not failed) (eq keep :crashed))
           (values :leave "it finished"))
          ((and most (>= recent most))
           (values :give-up (format nil "~d exits in ~d s" recent (key (job-plist job) :window 60))))
          (t
           (values :restart (format nil "exit ~a" (getf detail :exit)))))))

(defmethod decide ((job job) (kind (eql :sample)) detail)
  (let ((memory (key (world-spec job) :memory))
        (most-resident (key (job-plist job) :most-resident 9/10))
        (resident (getf detail :resident-mb))
        (cpu (getf detail :cpu-share))
        (most-cpu (key (job-plist job) :most-cpu)))
    (cond ((and memory resident
                (> resident (* memory most-resident)))
           (values :quarantine (format nil "resident ~d MB of ~d" resident memory)))
          ((and most-cpu cpu
                (> cpu most-cpu))
           (values :quarantine (format nil "using ~d% of a cpu" (round (* 100 cpu)))))
          (t
           (values :leave nil)))))

(defun exited (job detail)
  (push (list* :time (get-universal-time) detail) (exits job))
  (multiple-value-bind (action why) (decide job :exit detail)
    (ecase action
      (:leave
       (if (or (keep-alive-p job) (world job))
           (note job :stopped why)
           (setf (state job) :stopped (reason job) why))
       nil)
      (:give-up
       (note job :failed why)
       (let ((failed (key (job-plist job) :when-failed)))
         (when failed
           (handler-case (funcall failed)
             (error (e) (log-line "~a: ~a" (label job) e)))))
       nil)
      (:restart
       (let ((delay (throttle job)))
         (note job :restarting (format nil "~a; again in ~d s" why (round delay)))
         delay)))))

(defun reaped (pid status)
  (sb-thread:with-mutex (*lock*)
    (let ((job (find pid *jobs* :key #'pid)))
      (when job
        (setf (pid job) nil
              (status job) status)
        (let ((delay (exited job (list :exit (exit-code status)))))
          (when delay
            (bsd:bsdthread-create (lambda ()
                                    (sleep delay)
                                    (sb-thread:with-mutex (*lock*) (start job)))
                                  "throttle")))))))

(defun beat-form (seconds)
  (let ((every (max 1/2 (/ seconds 3))))
    (format nil "(progn (sb-thread:make-thread (lambda () (loop (sb-alien:alien-funcall (sb-alien:extern-alien \"__machdep5\" (function sb-alien:long sb-alien:long sb-alien:unsigned-long sb-alien:unsigned-long sb-alien:unsigned-long sb-alien:unsigned-long sb-alien:unsigned-long)) 52 ~d 0 0 0 0) (sleep ~f))) :name \"heartbeat\") t)"
            seconds (float every))))

(defun open-world (job)
  (let* ((spec (world-spec job))
         (world (darterfly/run:new-world (label job)
                                         :core (key spec :core "/usr/lib/sbcl/sbcl.core")
                                         :cwd (key spec :cwd "/")
                                         :evals (key spec :evals (list "(loop (sleep 60))"))
                                         :memory (key spec :memory)))
         (seconds (key (job-plist job) :heartbeat)))
    (setf (world job) world
          (cpu job) nil
          (started job) (get-internal-real-time))
    (handler-case
        (let ((after (key (job-plist job) :after-start)))
          (when seconds
            (darterfly/run:await-answer world)
            (darterfly/run:world-eval world (beat-form seconds) :timeout 30))
          (when after
            (funcall after world)))
      (error (e)
        (ignore-errors (darterfly/run:stop-world world))
        (error e)))
    world))

(defun sample (job)
  (let* ((entry (find (darterfly/run:world-id (world job)) (darterfly/worlds:worlds)
                      :key (lambda (w) (getf w :id))))
         (cpu (getf entry :cpu-seconds))
         (now (get-internal-real-time))
         (last (cpu job)))
    (setf (cpu job) (cons now cpu))
    (when entry
      (list :resident-mb (getf entry :resident-mb)
            :cpu-share (and last cpu
                            (let ((seconds (/ (- now (car last)) internal-time-units-per-second)))
                              (and (plusp seconds)
                                   (/ (- cpu (cdr last)) seconds))))))))

(defun quarantine (job why)
  (darterfly/worlds:pause (darterfly/run:world-id (world job)))
  (note job :quarantined why))

(defun inspect-job (label)
  (let ((job (sb-thread:with-mutex (*lock*) (find-job label))))
    (unless job
      (error "no job ~a" label))
    (let ((id (and (world job) (darterfly/run:world-id (world job)))))
      (list :label label
            :state (state job)
            :reason (reason job)
            :exits (reverse (exits job))
            :world id
            :inside (and id
                         (eq (state job) :quarantined)
                         (darterfly/worlds:inspect-world id))))))

(defun check-health (job)
  (let ((healthy (key (job-plist job) :healthy))
        (now (get-universal-time)))
    (when (and healthy (>= (- now (checked-at job)) (key (job-plist job) :check-every 10)))
      (setf (checked-at job) now)
      (if (ignore-errors (funcall healthy))
          (setf (unhealthy-since job) nil)
          (let ((since (or (unhealthy-since job) (setf (unhealthy-since job) now))))
            (when (>= (- now since) (key (job-plist job) :unhealthy-for 60))
              (setf (unhealthy-since job) nil)
              (note job :unhealthy (format nil "unhealthy for ~d s" (- now since)))
              (darterfly/worlds:stop (darterfly/run:world-id (world job)))))))))

(defun wait-for-world (job)
  (let ((thread (darterfly/run::world-thread (world job))))
    (setf (checked-at job) (get-universal-time)
          (unhealthy-since job) nil)
    (loop
      (let ((result (sb-thread:join-thread thread :default :running :timeout *sample-every*)))
        (unless (eq result :running)
          (return result)))
      (check-health job)
      (when (eq (state job) :running)
        (let ((detail (sample job)))
          (when detail
            (multiple-value-bind (action why) (decide job :sample detail)
              (when (eq action :quarantine)
                (quarantine job why)))))))))

(defun watch (job)
  (loop
    (let* ((result (handler-case (progn (open-world job)
                                        (note job :running nil)
                                        (wait-for-world job))
                     (error (e)
                       (list :exit :refused :why (princ-to-string e)))))
           (delay (exited job result)))
      (unless delay
        (when (removing job)
          (sb-thread:with-mutex (*lock*)
            (setf *jobs* (remove job *jobs*))))
        (return))
      (sleep delay))))

(defun start-in-world (job)
  (unless (and (watcher job) (sb-thread:thread-alive-p (watcher job)))
    (setf (exits job) nil)
    (note job :starting nil)
    (setf (watcher job) (sb-thread:make-thread (lambda () (watch job))
                                               :name (format nil "job ~a" (label job))))))

(defun find-job (label)
  (find label *jobs* :key #'label :test #'string=))

(defun submit-job (message plist)
  (let ((old (find-job (key plist :label))))
    (cond ((and old (member (state old) '(:starting :running :restarting :quarantined :unhealthy)))
           (fail-reply message :job-active))
          (t
           (let ((job (load-job plist)))
             (if (null job)
                 (fail-reply message :bad-job)
                 (progn
                   (setf *jobs* (append (remove old *jobs*) (list job)))
                   (when (start-at-load-p job)
                     (start job))
                   (reply message (list :label (label job))))))))))

(defun release-job (message label)
  (let ((job (find-job label)))
    (cond ((null job) (fail-reply message :unknown-job))
          ((not (eq (state job) :quarantined)) (fail-reply message :not-quarantined))
          (t
           (darterfly/worlds:resume (darterfly/run:world-id (world job)))
           (setf (cpu job) nil)
           (note job :running "released")
           (reply message (list :label label))))))

(defun withdraw-job (message label)
  (let ((job (find-job label)))
    (cond ((null job) (fail-reply message :unknown-job))
          (t
           (setf (removing job) t)
           (cond ((world job)
                  (when (eq (state job) :quarantined)
                    (darterfly/worlds:resume (darterfly/run:world-id (world job))))
                  (darterfly/worlds:stop (darterfly/run:world-id (world job))))
                 ((pid job)
                  (ignore-errors (bsd:kill (pid job) 15))))
           (unless (or (pid job)
                       (and (watcher job) (sb-thread:thread-alive-p (watcher job))))
             (setf *jobs* (remove job *jobs*)))
           (reply message (list :label label))))))

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
                                     :label (label job) :available (not (unavailable job))
                                     :state (state job) :reason (reason job)
                                     :world (and (world job) (darterfly/run:world-id (world job)))
                                     :exits (length (exits job))))
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
                  (destructuring-bind (op &key name label job &allow-other-keys) request
                    (case op
                      (:check-in (check-in message name (bsd:task-pid (mach:msgh-audit message))))
                      (:look-up (look-up message name))
                      (:list (list-jobs message))
                      (:launch (launch-job message label))
                      (:submit (submit-job message job))
                      (:release (release-job message label))
                      (:remove (withdraw-job message label))
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
    ;; Host-side service tests do not have the bare-metal watchdog syscall.
    (when (sb-sys:find-foreign-symbol-address "__machdep5")
      (sb-thread:make-thread #'darterfly/worlds:heartbeat :name "heartbeat"))
    (when (sb-sys:find-foreign-symbol-address "__machdep5")
      (sb-thread:make-thread (lambda () (sleep 2) (darterfly/run:restore-worlds)) :name "restore worlds"))
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

(defun answered (reply)
  (if (getf reply :error)
      (values nil (getf reply :error))
      (values (or (getf reply :label) t) nil)))

(defun submit (plist)
  (answered (init-call (list :submit :job plist))))

(defun release (label)
  (answered (init-call (list :release :label label))))

(defun remove-job (label)
  (answered (init-call (list :remove :label label))))

(defun jobs ()
  (getf (init-call (list :list)) :jobs))

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
