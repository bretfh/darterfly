(in-package #:darterfly/devices)

(defconstant +input-buffers+ 64)

(define-device-class virtio-input "VirtIOInput" (device)
  ((transport :accessor transport)
   (queue :accessor queue)
   (page :accessor event-page)
   (ranges :initform (make-hash-table) :reader abs-ranges)
   (lock :initform (sb-thread:make-mutex :name "virtio-input") :reader input-lock)))

(add-personality "Class" "VirtIOInput" "ProviderClass" "VirtIOTransport"
                 "VirtIOPrimaryMatch" "0x00121af4")

(defun input-config (tr select subsel)
  (mmio-write (device-cfg tr) 8 select)
  (mmio-write (+ (device-cfg tr) 1) 8 subsel)
  (let ((size (mmio-read (+ (device-cfg tr) 2) 8)))
    (coerce (loop for i below size collect (mmio-read (+ (device-cfg tr) 8 i) 8)) '(vector (unsigned-byte 8)))))

(defun le32 (v at) (logior (aref v at) (ash (aref v (+ at 1)) 8) (ash (aref v (+ at 2)) 16) (ash (aref v (+ at 3)) 24)))

(defun post-event-buffer (q id)
  (let* ((size (virtqueue-size q))
         (idx (ml-phys-read-16 (+ (virtqueue-avail q) 2))))
    (ml-phys-write-16 (+ (virtqueue-avail q) 4 (* 2 (mod idx size))) id)
    (sb-thread:barrier (:write))
    (ml-phys-write-16 (+ (virtqueue-avail q) 2) (ldb (byte 16 0) (1+ idx)))))

(defun post-buffers (q address length)
  (dotimes (i (virtqueue-size q))
    (let ((at (+ (virtqueue-desc q) (* 16 i))))
      (ml-phys-write-64 at (funcall address i))
      (ml-phys-write-32 (+ at 8) length)
      (ml-phys-write-16 (+ at 12) 2)
      (ml-phys-write-16 (+ at 14) 0))
    (post-event-buffer q i))
  (setf (virtqueue-free q) nil))

(defun post-input-buffers (in)
  (post-buffers (queue in) (lambda (i) (+ (event-page in) (* 8 i))) 8))

(defmethod start ((in virtio-input) (tr virtio-transport))
  (setf (transport in) tr)
  (when (and (logtest (device-features tr) (ash 1 32)) (set-driver-features tr (ash 1 32)))
    (let ((q (setup-queue tr 0 +input-buffers+))
          (page (vm-page-grab)))
      (setf (queue in) q (event-page in) page)
      (post-input-buffers in)
      (driver-ok tr)
      (mmio-write (virtqueue-notify q) 16 0)
      (let* ((name (input-config tr 1 0))
             (absolute (plusp (length (input-config tr #x11 3)))))
        (set-property in "Product" (map 'string #'code-char (remove 0 name)))
        (set-property in "VirtIOInputType"
                      (cond (absolute "Mouse") ((plusp (length (input-config tr #x11 2))) "Mouse") (t "Keyboard")))
        (when absolute
          (dolist (axis '(0 1))
            (let ((info (input-config tr #x12 axis)))
              (when (>= (length info) 8)
                (setf (gethash axis (abs-ranges in)) (cons (le32 info 0) (le32 info 4))))))))
      t)))

(defun input-events (in)
  "The events the device has finished since the last call, as (type code value)."
  (sb-thread:with-mutex ((input-lock in))
    (let* ((q (queue in)) (size (virtqueue-size q)) (events nil))
      (loop until (= (ml-phys-read-16 (+ (virtqueue-used q) 2)) (virtqueue-last-used q))
            do (sb-thread:barrier (:read))
               (let* ((slot (+ (virtqueue-used q) 4 (* 8 (mod (virtqueue-last-used q) size))))
                      (id (ml-phys-read-32 slot))
                      (at (+ (event-page in) (* 8 id)))
                      (value (ml-phys-read-32 (+ at 4))))
                 (push (list (ml-phys-read-16 at) (ml-phys-read-16 (+ at 2))
                             (if (logbitp 31 value) (- value (ash 1 32)) value))
                       events)
                 (setf (virtqueue-last-used q) (ldb (byte 16 0) (1+ (virtqueue-last-used q))))
                 (post-event-buffer q id)))
      (when events (mmio-write (virtqueue-notify q) 16 0))
      (nreverse events))))

(defmethod suspend ((in virtio-input)) (sb-thread:grab-mutex (input-lock in)))

(defmethod wake ((in virtio-input))
  (when (sb-thread:holding-mutex-p (input-lock in))
    (unwind-protect
         (progn (restart-transport (transport in))
                (post-input-buffers in)
                (driver-ok (transport in))
                (mmio-write (virtqueue-notify (queue in)) 16 0))
      (sb-thread:release-mutex (input-lock in)))))

(defun input-abs-range (in axis) (gethash axis (abs-ranges in)))

(defmethod interrupt-vector ((in virtio-input)) (virtqueue-vector (queue in)))
