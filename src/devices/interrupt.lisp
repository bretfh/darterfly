(in-package #:finch/devices)

(defconstant +keyboard-vector+ #x3F)
(defvar *free-vectors* (loop for v from #x30 below +keyboard-vector+ collect v))
(defvar *vectors-lock* (sb-thread:make-mutex :name "interrupt vectors"))

(defun allocate-vector () (sb-thread:with-mutex (*vectors-lock*) (pop *free-vectors*)))
(defun free-vector (vector) (sb-thread:with-mutex (*vectors-lock*) (push vector *free-vectors*)))

(defun wait-for-interrupt (vectors &optional timeout)
  (let ((fired (machdep 12 (loop for v in vectors sum (ash 1 (- v #x30)))
                        (if timeout (max 1 (round (* timeout 1000000))) 0))))
    (loop for v in vectors when (logbitp (- v #x30) fired) collect v)))

(defun enable-msi-x (device)
  (let ((cap (find-pci-capability device #x11)))
    (when cap
      (let* ((control (config-read-16 device (+ cap 2)))
             (table (config-read-32 device (+ cap 4)))
             (map (map-device-memory-with-index device (logand table 7))))
        (when map
          (config-write-16 device (+ cap 2) (logior (logandc2 control #x4000) #x8000))
          (values (+ (map-virtual-address map) (logandc2 table 7)) (1+ (logand control #x7ff))))))))

(defun set-msi-x-vector (table entry vector)
  (let ((at (+ table (* 16 entry))))
    (mmio-write at 32 (logior #xfee00000 (ash (ml-get-apicid) 12)))
    (mmio-write (+ at 4) 32 0)
    (mmio-write (+ at 8) 32 vector)
    (mmio-write (+ at 12) 32 0)))

(defgeneric interrupt-vector (service))
