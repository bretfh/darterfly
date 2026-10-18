(defpackage #:darterfly/power
  (:use #:cl)
  (:export #:flush-disks #:restart #:shut-down #:suspend #:restart-soon #:save-system #:*save-system*
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

(defun sleep-type (state)
  (loop for v in (darterfly/devices::definition-blocks)
        for at = (search (vector 8 95 83 (+ 48 state) 95 18) v)
        when at
          return (let ((p (+ at 6)))
                   (multiple-value-bind (length used) (darterfly/devices::aml-pkg-length v p)
                     (declare (ignore length))
                     (package-integer v (+ p used 1))))))

(defun s5-sleep-type () (sleep-type 5))

(defun suspend ()
  (let* ((fadt (darterfly/devices::acpi-table "FACP"))
         (length (and fadt (darterfly/devices::ml-phys-read-32 (+ fadt 4))))
         (control (and fadt (darterfly/devices::ml-phys-read-32 (+ fadt 64))))
         (event (and fadt (darterfly/devices::ml-phys-read-32 (+ fadt 56))))
         (facs (and fadt (let ((x (and (>= length 140) (darterfly/devices::ml-phys-read-64 (+ fadt 132)))))
                           (if (and x (plusp x)) x (darterfly/devices::ml-phys-read-32 (+ fadt 36))))))
         (type (sleep-type 3)))
    (unless (and control (plusp control) event (plusp event) facs (plusp facs) type)
      (error "suspend: the firmware offers no S3"))
    (flush-disks)
    (darterfly/devices::suspend-devices)
    (let ((enables (quiet-gpes fadt)))
      (unwind-protect (darterfly/devices:machdep 66 (logior control (ash event 16) (ash type 32)) facs)
        (restore-gpes fadt enables)
        (darterfly/devices::wake-devices)))))

(defun gpe-block (fadt)
  (let ((port (darterfly/devices::ml-phys-read-32 (+ fadt 80)))
        (length (darterfly/devices::ml-phys-read-8 (+ fadt 92))))
    (and (plusp port) (plusp length) (values port (floor length 2)))))

(defun quiet-gpes (fadt)
  (multiple-value-bind (port half) (gpe-block fadt)
    (when port
      (loop for i below half
            collect (prog1 (darterfly/devices::port-read-8 (+ port half i))
                      (darterfly/devices::port-write-8 (+ port half i) 0)
                      (darterfly/devices::port-write-8 (+ port i) #xFF))))))

(defun restore-gpes (fadt enables)
  (multiple-value-bind (port half) (gpe-block fadt)
    (when port
      (loop for i below half
            for enable in enables
            do (darterfly/devices::port-write-8 (+ port i) #xFF)
               (darterfly/devices::port-write-8 (+ port half i) enable)))))

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
