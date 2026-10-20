(defpackage #:darterfly/power
  (:use #:cl)
  (:export #:flush-disks #:flush-failed #:restart #:shut-down #:suspend #:restart-soon #:save-system #:*save-system*
           #:note-activity #:dim-when-idle #:*dim-after* #:*dim-to*)
  (:shadow #:restart))
(in-package #:darterfly/power)

(define-condition flush-failed (error)
  ((failures :initarg :failures :reader flush-failures))
  (:report (lambda (c s)
             (format s "flushing the disks failed: ~{~a~^; ~}" (flush-failures c)))))

(defun flush-disks ()
  (let ((failures nil))
    (handler-case (darterfly/vfs:vfs-sync)
      (error (e) (push (format nil "sync: ~a" e) failures)))
    (dolist (m (darterfly/devices:find-entries 'darterfly/devices:media))
      (when (darterfly/devices:get-property m "Whole")
        (handler-case (darterfly/devices:media-flush m)
          (error (e) (push (format nil "~a: ~a" (darterfly/devices:entry-name m) e) failures)))))
    (when failures
      (error 'flush-failed :failures (nreverse failures)))
    t))

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

(defun cmos (register)
  (darterfly/devices::port-write-8 #x70 register)
  (darterfly/devices::port-read-8 #x71))

(defun (setf cmos) (value register)
  (darterfly/devices::port-write-8 #x70 register)
  (darterfly/devices::port-write-8 #x71 value)
  value)

(defun arm-rtc-wake (event seconds)
  (let* ((binary (logbitp 2 (cmos #x0B)))
         (now (progn (loop while (logbitp 7 (cmos #x0A))) (cmos 0)))
         (at (mod (+ (if binary now (+ (* 10 (ash now -4)) (logand now 15))) seconds) 60))
         (enable (darterfly/devices::port-read-16 (+ event 2))))
    (setf (cmos 1) (if binary at (+ (* 16 (floor at 10)) (mod at 10)))
          (cmos 3) #xC0
          (cmos 5) #xC0)
    (cmos #x0C)
    (setf (cmos #x0B) (logior (cmos #x0B) #x20))
    (darterfly/devices::port-write-16 (+ event 2) (logior enable #x400))
    enable))

(defun disarm-rtc-wake (event enable)
  (setf (cmos #x0B) (logand (cmos #x0B) (lognot #x20)))
  (cmos #x0C)
  (darterfly/devices::port-write-16 (+ event 2) enable))

(defvar *suspend-lock* (sb-thread:make-mutex :name "system suspend"))
(defvar *suspend-state* nil)

(defun suspend-phase (phase &rest detail)
  (setf *suspend-state* (list* :phase phase :since (get-internal-real-time) detail)))

(defun suspend (&key check wake-after)
  (unless (sb-thread:grab-mutex *suspend-lock* :waitp nil)
    (error "suspend: another transition is in progress"))
  (unwind-protect
       (handler-case
           (let ((result (perform-suspend :check check :wake-after wake-after)))
             (suspend-phase :awake :wake-count result)
             result)
         (error (e)
           (suspend-phase :failed :error (princ-to-string e))
           (error e)))
    (sb-thread:release-mutex *suspend-lock*)))

(defun perform-suspend (&key check wake-after)
  (let* ((fadt (darterfly/devices::acpi-table "FACP"))
         (length (and fadt (darterfly/devices::ml-phys-read-32 (+ fadt 4))))
         (control (and fadt (darterfly/devices::ml-phys-read-32 (+ fadt 64))))
         (event (and fadt (darterfly/devices::ml-phys-read-32 (+ fadt 56))))
         (facs (and fadt (let ((x (and (>= length 140) (darterfly/devices::ml-phys-read-64 (+ fadt 132)))))
                           (if (and x (plusp x)) x (darterfly/devices::ml-phys-read-32 (+ fadt 36))))))
         (type (sleep-type 3)))
    (unless (and control (plusp control) event (plusp event) facs (plusp facs) type)
      (error "suspend: the firmware offers no S3"))
    (suspend-phase :flushing)
    (flush-disks)
    ;; Establish cleanup before taking any driver locks. In particular, an RTC
    ;; setup failure must not leave the display and disks suspended forever.
    (unwind-protect
         (progn
           (suspend-phase :suspending-devices)
           (darterfly/devices::suspend-devices)
           (let ((enables (quiet-gpes fadt)))
             (unwind-protect
                  (let ((rtc (and wake-after (arm-rtc-wake event wake-after))))
                    (unwind-protect
                         (progn
                           (suspend-phase :sleeping)
                           (darterfly/devices:machdep 66
                             (logior control (ash event 16) (ash type 32) (if check (ash 1 35) 0)) facs))
                      (when rtc (disarm-rtc-wake event rtc))))
               (restore-gpes fadt enables))))
      (suspend-phase :waking-devices)
      (darterfly/devices::wake-devices))))

(defun changed-memory ()
  (let ((buffer (make-array 4098 :element-type '(unsigned-byte 64))))
    (sb-sys:with-pinned-objects (buffer)
      (let* ((n (min 4096 (darterfly/devices:machdep 68 (sb-sys:sap-int (sb-sys:vector-sap buffer)) 4096)))
             (chunks (sort (coerce (subseq buffer 2 (+ 2 n)) 'list) #'<)))
        (loop with runs = nil
              for pa in chunks
              do (if (and runs (= pa (cdr (first runs))))
                     (setf (cdr (first runs)) (+ pa #x10000))
                     (push (cons pa (+ pa #x10000)) runs))
              finally (return (list :ms (list (aref buffer 0) (aref buffer 1))
                                    :ranges (mapcar (lambda (r) (list (format nil "~x" (car r)) (format nil "~x" (cdr r)) (floor (- (cdr r) (car r)) 1024)))
                                                    (nreverse runs)))))))))

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
