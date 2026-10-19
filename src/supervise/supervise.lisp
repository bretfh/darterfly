(defpackage #:darterfly/supervise
  (:use #:cl)
  (:export #:policy #:decide #:supervise #:supervised #:find-supervised #:release #:discard #:stop
           #:supervised-name #:supervised-world #:supervised-state #:supervised-reason #:supervised-exits
           #:*sample-every*))
(in-package #:darterfly/supervise)

(defparameter *sample-every* 2)

(defclass policy ()
  ((restart :initarg :restart :initform :on-failure :accessor policy-restart)
   (backoff :initarg :backoff :initform 1 :accessor policy-backoff)
   (most-backoff :initarg :most-backoff :initform 60 :accessor policy-most-backoff)
   (window :initarg :window :initform 60 :accessor policy-window)
   (most-exits :initarg :most-exits :initform 5 :accessor policy-most-exits)
   (heartbeat :initarg :heartbeat :initform nil :accessor policy-heartbeat)
   (most-resident :initarg :most-resident :initform 9/10 :accessor policy-most-resident)
   (most-cpu :initarg :most-cpu :initform nil :accessor policy-most-cpu)))

(defclass supervised ()
  ((name :initarg :name :reader supervised-name)
   (start :initarg :start :reader supervised-start)
   (memory :initarg :memory :initform nil :reader supervised-memory)
   (policy :initarg :policy :accessor supervised-policy)
   (world :initform nil :accessor supervised-world)
   (state :initform :starting :accessor supervised-state)
   (reason :initform nil :accessor supervised-reason)
   (exits :initform nil :accessor supervised-exits)
   (cpu :initform nil :accessor supervised-cpu)
   (stopping :initform nil :accessor supervised-stopping)
   (thread :initform nil :accessor supervised-thread)))

(defvar *supervised* nil)
(defvar *supervised-lock* (sb-thread:make-mutex :name "supervised"))

(defgeneric decide (policy supervised kind detail))

(defun recent-exits (supervised)
  (let ((since (- (get-universal-time) (policy-window (supervised-policy supervised)))))
    (remove-if (lambda (exit) (< (getf exit :time) since))
               (supervised-exits supervised))))

(defmethod decide ((policy policy) supervised (kind (eql :exit)) detail)
  (let ((failed (not (eql 0 (getf detail :exit))))
        (recent (length (recent-exits supervised))))
    (cond ((supervised-stopping supervised)
           (values :leave "stopped on purpose"))
          ((eq (policy-restart policy) :never)
           (values :leave "its policy never restarts it"))
          ((and (not failed) (eq (policy-restart policy) :on-failure))
           (values :leave "it finished"))
          ((>= recent (policy-most-exits policy))
           (values :give-up (format nil "~d exits in ~d s" recent (policy-window policy))))
          (t
           (values :restart (format nil "exit ~a" (getf detail :exit)))))))

(defmethod decide ((policy policy) supervised (kind (eql :sample)) detail)
  (let ((memory (supervised-memory supervised))
        (resident (getf detail :resident-mb))
        (cpu (getf detail :cpu-share))
        (most-cpu (policy-most-cpu policy)))
    (cond ((and memory
                (> resident (* memory (policy-most-resident policy))))
           (values :quarantine (format nil "resident ~d MB of ~d" resident memory)))
          ((and most-cpu cpu
                (> cpu most-cpu))
           (values :quarantine (format nil "using ~d% of a cpu" (round (* 100 cpu)))))
          (t
           (values :leave nil)))))

(defun backoff (supervised)
  (let* ((policy (supervised-policy supervised))
         (recent (length (recent-exits supervised)))
         (doubled (* (policy-backoff policy)
                     (expt 2 (max 0 (1- recent))))))
    (min doubled (policy-most-backoff policy))))

(defun note (supervised state reason)
  (setf (supervised-state supervised) state
        (supervised-reason supervised) reason)
  (format *error-output* "~&supervise: ~a ~(~a~)~@[: ~a~]~%" (supervised-name supervised) state reason))

(defun beat-form (seconds)
  (let ((every (max 1/2 (/ seconds 3))))
    (format nil "(progn (sb-thread:make-thread (lambda () (loop (sb-alien:alien-funcall (sb-alien:extern-alien \"__machdep5\" (function sb-alien:long sb-alien:long sb-alien:unsigned-long sb-alien:unsigned-long sb-alien:unsigned-long sb-alien:unsigned-long sb-alien:unsigned-long)) 52 ~d 0 0 0 0) (sleep ~f))) :name \"heartbeat\") t)"
            seconds (float every))))

(defun answering (world)
  (loop repeat 300
        when (ignore-errors (darterfly/run:world-eval world "t" :timeout 5))
          return t
        do (sleep 0.1)))

(defun start-once (supervised)
  (let ((world (funcall (supervised-start supervised))))
    (setf (supervised-world supervised) world
          (supervised-cpu supervised) nil)
    (let ((seconds (policy-heartbeat (supervised-policy supervised))))
      (when (and seconds (answering world))
        (darterfly/run:world-eval world (beat-form seconds) :timeout 30)))
    world))

(defun sample (supervised)
  (let* ((world (supervised-world supervised))
         (entry (find (darterfly/run:world-id world) (darterfly/worlds:worlds)
                      :key (lambda (w) (getf w :id))))
         (cpu (getf entry :cpu-seconds))
         (now (get-internal-real-time))
         (last (supervised-cpu supervised)))
    (setf (supervised-cpu supervised) (cons now cpu))
    (when entry
      (list :resident-mb (getf entry :resident-mb)
            :cpu-share (and last cpu
                            (let ((seconds (/ (- now (car last)) internal-time-units-per-second)))
                              (and (plusp seconds)
                                   (/ (- cpu (cdr last)) seconds))))))))

(defun quarantine (supervised reason)
  (darterfly/worlds:pause (darterfly/run:world-id (supervised-world supervised)))
  (note supervised :quarantined reason))

(defun wait-for-exit (supervised)
  (let ((thread (darterfly/run::world-thread (supervised-world supervised))))
    (loop
      (let ((result (sb-thread:join-thread thread :default :running :timeout *sample-every*)))
        (unless (eq result :running)
          (return result)))
      (when (eq (supervised-state supervised) :running)
        (let ((detail (sample supervised)))
          (when detail
            (multiple-value-bind (action reason)
                (decide (supervised-policy supervised) supervised :sample detail)
              (when (eq action :quarantine)
                (quarantine supervised reason)))))))))

(defun watch (supervised)
  (loop
    (let ((result (handler-case (progn (start-once supervised)
                                       (note supervised :running nil)
                                       (wait-for-exit supervised))
                    (error (e)
                      (list :exit :refused :why (princ-to-string e))))))
      (push (list* :time (get-universal-time) result) (supervised-exits supervised))
      (multiple-value-bind (action reason)
          (decide (supervised-policy supervised) supervised :exit result)
        (ecase action
          (:leave
           (note supervised :stopped reason)
           (return))
          (:give-up
           (note supervised :failed reason)
           (return))
          (:restart
           (let ((wait (backoff supervised)))
             (note supervised :restarting (format nil "~a; again in ~d s" reason wait))
             (sleep wait))))))))

(defun find-supervised (name)
  (sb-thread:with-mutex (*supervised-lock*)
    (find name *supervised* :key #'supervised-name :test #'equal)))

(defun supervise (name &key (policy (make-instance 'policy)) memory (core "/usr/lib/sbcl/sbcl.core") (cwd "/")
                            (evals (list "(loop (sleep 60))")))
  (let ((old (find-supervised name)))
    (when (and old (member (supervised-state old) '(:starting :running :restarting :quarantined)))
      (error "~a is already supervised (~(~a~))" name (supervised-state old))))
  (let ((supervised (make-instance 'supervised
                                   :name name :policy policy :memory memory
                                   :start (lambda ()
                                            (darterfly/run:new-world name :core core :cwd cwd :evals evals :memory memory)))))
    (sb-thread:with-mutex (*supervised-lock*)
      (setf *supervised* (cons supervised (remove name *supervised* :key #'supervised-name :test #'equal))))
    (setf (supervised-thread supervised)
          (sb-thread:make-thread (lambda () (watch supervised))
                                 :name (format nil "supervise ~a" name)))
    supervised))

(defun supervised ()
  (sb-thread:with-mutex (*supervised-lock*)
    (loop for s in (reverse *supervised*)
          collect (list :name (supervised-name s)
                        :state (supervised-state s)
                        :reason (supervised-reason s)
                        :world (and (supervised-world s) (darterfly/run:world-id (supervised-world s)))
                        :exits (length (supervised-exits s))))))

(defun the-supervised (name)
  (or (find-supervised name) (error "~a isn't supervised" name)))

(defun release (name)
  (let ((supervised (the-supervised name)))
    (unless (eq (supervised-state supervised) :quarantined)
      (error "~a isn't quarantined" name))
    (darterfly/worlds:resume (darterfly/run:world-id (supervised-world supervised)))
    (setf (supervised-cpu supervised) nil)
    (note supervised :running "released")))

(defun stop (name)
  (let ((supervised (the-supervised name)))
    (setf (supervised-stopping supervised) t)
    (when (eq (supervised-state supervised) :quarantined)
      (darterfly/worlds:resume (darterfly/run:world-id (supervised-world supervised))))
    (ignore-errors (darterfly/run:stop-world (supervised-world supervised)))
    (sb-thread:join-thread (supervised-thread supervised) :default nil :timeout 30)
    (supervised-state supervised)))

(defun discard (name)
  (stop name)
  (sb-thread:with-mutex (*supervised-lock*)
    (setf *supervised* (remove name *supervised* :key #'supervised-name :test #'equal)))
  name)
