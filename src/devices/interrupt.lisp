(in-package #:darterfly/devices)

(defconstant +keyboard-vector+ #x3F)
(defvar *free-vectors* (loop for v from #x30 below +keyboard-vector+ collect v))
(defvar *vectors-lock* (sb-thread:make-mutex :name "interrupt vectors"))

(defun allocate-vector () (sb-thread:with-mutex (*vectors-lock*) (pop *free-vectors*)))
(defun free-vector (vector) (sb-thread:with-mutex (*vectors-lock*) (push vector *free-vectors*)))

(defvar *interrupts-lock* (sb-thread:make-mutex :name "interrupts"))
(defvar *interrupted* (sb-thread:make-waitqueue :name "interrupts"))
(defvar *interrupt-counts* (make-array 64 :initial-element 0))
(defvar *dispatchers* (make-hash-table))
(defvar *seen* (make-hash-table :test 'eq :weakness :key :synchronized t))

(pushnew 'forget-interrupts sb-ext:*save-hooks*)

(defun forget-interrupts ()
  (setf *dispatchers* (make-hash-table))
  (clrhash *seen*))

(defconstant +input-vector+ #x6F)

(defun note-interrupt (vector)
  (sb-thread:with-mutex (*interrupts-lock*)
    (incf (aref *interrupt-counts* (- vector #x30)))
    (sb-thread:condition-broadcast *interrupted*)))

(defun dispatch (vector)
  (loop
    (when (plusp (machdep 12 (ash 1 (- vector #x30)) 1000000))
      (sb-thread:with-mutex (*interrupts-lock*)
        (incf (aref *interrupt-counts* (- vector #x30)))
        (sb-thread:condition-broadcast *interrupted*)))))

(defun ensure-dispatcher (vector)
  (unless (or (= vector +input-vector+) (gethash vector *dispatchers*))
    (let ((recording (find-symbol "*RECORDING*" "DARTERFLY/BSD")))
      (progv (and recording (list recording)) '(nil)
        (setf (gethash vector *dispatchers*)
              (sb-thread:make-thread #'dispatch :name (format nil "interrupt #x~x" vector) :arguments (list vector)))))))

(defun wait-for-interrupt (vectors &optional timeout)
  (let ((deadline (and timeout (+ (get-internal-real-time) (round (* timeout internal-time-units-per-second))))))
    (sb-thread:with-mutex (*interrupts-lock*)
      (mapc #'ensure-dispatcher vectors)
      (let ((seen (or (gethash sb-thread:*current-thread* *seen*)
                      (setf (gethash sb-thread:*current-thread* *seen*) (make-array 64 :initial-element 0)))))
        (loop
          (let ((fired (loop for v in vectors
                             unless (= (aref seen (- v #x30)) (aref *interrupt-counts* (- v #x30)))
                               collect v)))
            (when fired
              (dolist (v vectors) (setf (aref seen (- v #x30)) (aref *interrupt-counts* (- v #x30))))
              (return fired))
            (let ((left (and deadline (/ (- deadline (get-internal-real-time)) internal-time-units-per-second))))
              (when (and left (<= left 0)) (return nil))
              (sb-thread:condition-wait *interrupted* *interrupts-lock* :timeout left))))))))

(defun enable-msi-x (device)
  (let ((cap (find-pci-capability device #x11)))
    (when cap
      (let* ((control (config-read-16 device (+ cap 2)))
             (table (config-read-32 device (+ cap 4)))
             (map (map-device-memory-with-index device (logand table 7))))
        (when map
          (config-write-16 device (+ cap 2) (logior (logandc2 control #x4000) #x8000))
          (values (+ (map-virtual-address map) (logandc2 table 7)) (1+ (logand control #x7ff))))))))

(defun enable-msi (device vector)
  (let ((cap (find-pci-capability device #x05)))
    (when cap
      (let ((control (config-read-16 device (+ cap 2))))
        (config-write-32 device (+ cap 4) (logior #xfee00000 (ash (ml-get-apicid) 12)))
        (if (logbitp 7 control)
            (progn (config-write-32 device (+ cap 8) 0)
                   (config-write-16 device (+ cap 12) vector))
            (config-write-16 device (+ cap 8) vector))
        (config-write-16 device (+ cap 2) (logior (logandc2 control #x70) 1))
        (config-write-16 device 4 (logior (config-read-16 device 4) #x400))
        vector))))

(defun set-msi-x-vector (table entry vector)
  (let ((at (+ table (* 16 entry))))
    (mmio-write at 32 (logior #xfee00000 (ash (ml-get-apicid) 12)))
    (mmio-write (+ at 4) 32 0)
    (mmio-write (+ at 8) 32 vector)
    (mmio-write (+ at 12) 32 0)))

(defgeneric interrupt-vector (service))
