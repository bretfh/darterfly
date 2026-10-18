(in-package #:darterfly/display)

(defconstant +driver-wells+ #x45404)
(defconstant +dssm+ #x51004)
(defconstant +dc5-count+ #x101084)
(defconstant +dc6-count+ #x101088)
(defconstant +wells-beyond-pipe-a+ (logior (ash 1 3) (ash 1 13) (ash 1 15)))

(defvar *dc-target* 0)
(defvar *awake* 0)
(defvar *asleep-after* 0)
(defvar *power-lock* (sb-thread:make-mutex :name "display power"))
(defvar *power-changed* (sb-thread:make-waitqueue :name "display power"))
(defvar *dc-thread* nil)

(pushnew 'forget-power sb-ext:*save-hooks*)

(defun forget-power () (setf *dc-target* 0 *awake* 0 *dc-thread* nil))

(defun wait-until (what test &key (seconds 0.1))
  (let ((deadline (+ (get-internal-real-time) (* seconds internal-time-units-per-second))))
    (loop until (funcall test)
          do (when (> (get-internal-real-time) deadline) (error "timed out waiting for ~a" what))
             (sleep 0.0001))))

(defun write-dc-state (value)
  (let ((state (logior (logandc2 (reg +dc-state-en+) 3) value)))
    (setf (reg +dc-state-en+) state)
    (loop with rereads = 0
          for rewrites from 0 below 100
          do (if (= (reg +dc-state-en+) state)
                 (when (> (incf rereads) 5) (return state))
                 (setf (reg +dc-state-en+) state rereads 0))
          finally (error "DC_STATE_EN would not hold ~x" state))))

(defun registers-alive-p () (plusp (reg +dssm+)))

(defun wake ()
  (write-dc-state 0)
  (wait-until "the display registers to come back" #'registers-alive-p :seconds 0.05))

(defun dc-loop ()
  (sb-thread:with-mutex (*power-lock*)
    (loop
      (if (and (zerop *awake*) (plusp *dc-target*))
          (let ((left (- *asleep-after* (get-internal-real-time))))
            (if (plusp left)
                (sb-thread:condition-wait *power-changed* *power-lock* :timeout (/ left internal-time-units-per-second))
                (progn (unless (= (logand (reg +dc-state-en+) 3) *dc-target*)
                         (write-dc-state *dc-target*))
                       (sb-thread:condition-wait *power-changed* *power-lock*))))
          (sb-thread:condition-wait *power-changed* *power-lock*)))))

(defun call-awake (function)
  (sb-thread:with-recursive-lock (*power-lock*)
    (when (= 1 (incf *awake*))
      (handler-bind ((error (lambda (e) (declare (ignore e)) (decf *awake*))))
        (wake))))
  (unwind-protect (funcall function)
    (sb-thread:with-recursive-lock (*power-lock*)
      (when (zerop (decf *awake*))
        (setf *asleep-after* (+ (get-internal-real-time) (ceiling (* 17 internal-time-units-per-second) 1000)))
        (sb-thread:condition-notify *power-changed*)))))

(defmacro awake (&body body) `(call-awake (lambda () ,@body)))

(defun release-unused-wells ()
  (awake
    (let ((wells (reg +driver-wells+)))
      (when (zerop wells) (error "the power-well register reads dead"))
      (when (loop for transcoder in '(#x71008 #x72008 #x73008) thereis (logbitp 31 (reg transcoder)))
        (error "a transcoder other than A is running"))
      (setf (reg +driver-wells+) (logandc2 wells +wells-beyond-pipe-a+))
      (wait-until "power wells 2, B and C to go down"
                  (lambda () (not (logtest (reg +driver-wells+) (ash +wells-beyond-pipe-a+ -1)))) :seconds 0.05)
      (reg +driver-wells+))))

(defun allow-dc6 ()
  (sb-thread:with-recursive-lock (*power-lock*)
    (setf *dc-target* 2)
    (unless (and *dc-thread* (sb-thread:thread-alive-p *dc-thread*))
      (setf *dc-thread* (sb-thread:make-thread #'dc-loop :name "display dc")))
    (sb-thread:condition-notify *power-changed*)))

(defun forbid-dc ()
  (sb-thread:with-recursive-lock (*power-lock*)
    (setf *dc-target* 0)
    (when (zerop *awake*) (wake))))

(defun trace-power (seconds)
  (let ((log nil) (last nil)
        (deadline (+ (get-internal-real-time) (* seconds internal-time-units-per-second)))
        (start (get-internal-real-time)))
    (loop while (< (get-internal-real-time) deadline)
          do (let ((now (list (reg +dc-state-en+) (reg +dc5-count+) (reg +dc6-count+) (reg +driver-wells+) *awake*)))
               (unless (equal now last)
                 (push (cons (round (* 1000 (- (get-internal-real-time) start)) internal-time-units-per-second) now) log)
                 (setf last now)))
             (sleep 0.001))
    (nreverse log)))
