(defpackage #:darterfly/power
  (:use #:cl)
  (:export #:flush-disks #:restart #:shut-down #:restart-soon #:save-system #:*save-system*
           #:note-activity #:dim-when-idle #:*dim-after* #:*dim-to*)
  (:shadow #:restart))
(in-package #:darterfly/power)

(defun flush-disks ()
  (darterfly/vfs:vfs-sync)
  (dolist (m (darterfly/devices:find-entries 'darterfly/devices:media))
    (when (darterfly/devices:get-property m "Whole")
      (ignore-errors (darterfly/devices:media-flush m)))))

(defvar *save-system* nil)

(defun save-system (&key then)
  (cond (*save-system*
         (handler-case (funcall *save-system* :then then)
           (error (e)
             (format *error-output* "~&save: ~a~%" e)
             (case then
               (:restart (restart))
               (:shut-down (shut-down))
               (t (error e))))))
        ((eq then :restart) (restart))
        ((eq then :shut-down) (shut-down))
        (t (error "save: nothing knows how to save this system"))))

(defun restart ()
  (flush-disks)
  (darterfly/devices:machdep 26))

(defun restart-soon (&optional (seconds 2))
  (let ((darterfly/bsd:*recording* nil))
    (sb-thread:make-thread (lambda () (sleep seconds) (restart)) :name "restart"))
  :restarting)

(defun package-integer (v at)
  (case (aref v at)
    (0 (values 0 1))
    (1 (values 1 1))
    (#x0a (values (aref v (1+ at)) 2))
    (#x0b (values (logior (aref v (1+ at)) (ash (aref v (+ at 2)) 8)) 3))))

(defun s5-sleep-type ()
  (loop for v in (darterfly/devices::definition-blocks)
        for at = (search #(8 95 83 53 95 18) v)
        when at
          return (let ((p (+ at 6)))
                   (multiple-value-bind (length used) (darterfly/devices::aml-pkg-length v p)
                     (declare (ignore length))
                     (package-integer v (+ p used 1))))))

(defun shut-down ()
  (let* ((fadt (darterfly/devices::acpi-table "FACP"))
         (port (and fadt (darterfly/devices::ml-phys-read-32 (+ fadt 64))))
         (type (s5-sleep-type)))
    (unless (and port (plusp port) type)
      (error "shut down: no ACPI sleep control"))
    (flush-disks)
    (darterfly/devices:machdep 27 port (logior (ash type 10) (ash 1 13)))))

(defparameter *dim-after* 120)
(defparameter *dim-to* 0.3)

(defvar *last-activity* (get-internal-real-time))
(defvar *dimmed-from* nil)
(defvar *idle-waiting* nil)
(defvar *dim-lock* (sb-thread:make-mutex :name "dimming"))
(defvar *activity* (sb-thread:make-waitqueue))

(defun idle-seconds ()
  (/ (- (get-internal-real-time) *last-activity*) internal-time-units-per-second))

(defun note-activity ()
  (setf *last-activity* (get-internal-real-time))
  (when (or *dimmed-from* *idle-waiting*)
    (sb-thread:with-mutex (*dim-lock*)
      (when *dimmed-from*
        (darterfly/devices:set-brightness (shiftf *dimmed-from* nil) :save nil))
      (sb-thread:condition-broadcast *activity*))))

(defun dim-display ()
  (let ((now (darterfly/devices:brightness)))
    (when (and now (null *dimmed-from*) (> now (* 1.5 (max 0.05 (* now *dim-to*)))))
      (setf *dimmed-from* now)
      (darterfly/devices:set-brightness (* now *dim-to*) :save nil))))

(defun dim-when-idle ()
  (loop
    (let ((left (- *dim-after* (idle-seconds))))
      (if (plusp left)
          (sleep left)
          (let ((seen *last-activity*))
            (sb-thread:with-mutex (*dim-lock*)
              (dim-display)
              (when (and *dimmed-from* (/= seen *last-activity*))
                (darterfly/devices:set-brightness (shiftf *dimmed-from* nil) :save nil))
              (setf *idle-waiting* t)
              (unwind-protect
                   (loop while (= seen *last-activity*)
                         do (sb-thread:condition-wait *activity* *dim-lock*))
                (setf *idle-waiting* nil))))))))
