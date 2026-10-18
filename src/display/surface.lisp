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
