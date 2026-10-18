(in-package #:darterfly/display)

(defconstant +gtt-offset+ #x800000)
(defconstant +plane-surface-live-a+ #x701AC)

(defun gtt-entry (offset)
  (let ((g (graphics)))
    (devices::ml-phys-read-64 (+ (devices::bar-address g 0) +gtt-offset+ (* 8 (floor offset 4096))))))

(defun second-surface (bytes)
  (when (and (graphics) (logbitp 31 (reg +plane-ctl-a+)) (zerop (reg +plane-surface-a+)))
    (let ((offset (* #x40000 (ceiling bytes #x40000))))
      (when (and (logbitp 0 (gtt-entry offset)) (logbitp 0 (gtt-entry (+ offset bytes -1))))
        offset))))

(defun show-surface (offset)
  (setf (reg +plane-surface-a+) offset))

(defun live-surface ()
  (reg +plane-surface-live-a+))

(defconstant +master-irq+ #x190010)
(defconstant +display-int-ctl+ #x44200)
(defconstant +pipe-a-imr+ #x44404)
(defconstant +pipe-a-iir+ #x44408)
(defconstant +pipe-a-ier+ #x4440C)
(defconstant +flip-done+ (ash 1 3))

(defvar *flip-vector* nil)
(defvar *flips-armed* nil)

(pushnew 'forget-flips sb-ext:*save-hooks*)

(defun forget-flips () (setf *flips-armed* nil))

(defun arm-flips ()
  (or *flips-armed*
      (let ((vector (or *flip-vector* (setf *flip-vector* (devices:allocate-vector)))))
        (devices::enable-msi (graphics) vector)
        (setf (reg +pipe-a-imr+) (logandc2 #xFFFFFFFF +flip-done+)
              (reg +pipe-a-ier+) (logior (reg +pipe-a-ier+) +flip-done+)
              (reg +pipe-a-iir+) (reg +pipe-a-iir+)
              (reg +display-int-ctl+) (ash 1 31)
              (reg +master-irq+) (ash 1 31))
        (setf *flips-armed* vector))))

(defun acknowledge-flips ()
  (setf (reg +master-irq+) 0)
  (setf (reg +pipe-a-iir+) (reg +pipe-a-iir+))
  (setf (reg +master-irq+) (ash 1 31)))

(defun wait-for-flip (offset &optional (seconds 0.05))
  (let ((vector (ignore-errors (arm-flips)))
        (deadline (+ (get-internal-real-time) (round (* seconds internal-time-units-per-second)))))
    (loop until (or (= (live-surface) offset) (> (get-internal-real-time) deadline))
          do (if vector
                 (progn (devices:wait-for-interrupt (list vector) 0.02) (acknowledge-flips))
                 (sleep 0.0005)))
    (when vector (acknowledge-flips))))
