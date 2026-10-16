(in-package #:finch/iokit)

(defconstant +net-header+ 12)
(defconstant +receive-buffers+ 32)

(define-io-class io-ethernet-controller "IOEthernetController" (io-service))

(defgeneric network-send (net frame))
(defgeneric network-receive (net))

(define-io-class virtio-network "VirtIONetwork" (io-ethernet-controller)
  ((transport :accessor transport)
   (receive :accessor receive-queue)
   (transmit :accessor transmit-queue)
   (pages :accessor receive-pages)
   (send-page :accessor send-page)
   (mac :accessor network-mac)
   (lock :initform (sb-thread:make-mutex :name "virtio-net") :reader network-lock)))

(define-io-class io-ethernet-interface "IOEthernetInterface" (io-service))

(add-personality "IOClass" "VirtIONetwork" "IOProviderClass" "VirtIOTransport"
                 "IOVirtIOPrimaryMatch" "0x00011af4")

(defconstant +virtio-net-f-mac+ (ash 1 5))



(defmethod start ((net virtio-network) (tr virtio-transport))
  (setf (transport net) tr)
  (let ((wanted (logior +virtio-f-version-1+ +virtio-net-f-mac+)))
    (when (and (= wanted (logand wanted (device-features tr))) (set-driver-features tr wanted))
      (let ((rx (setup-queue tr 0 +receive-buffers+))
            (tx (setup-queue tr 1 8))
            (pages (loop repeat +receive-buffers+ collect (vm-page-grab))))
        (setf (receive-queue net) rx (transmit-queue net) tx (receive-pages net) (coerce pages 'vector)
              (send-page net) (vm-page-grab))
        (dotimes (i (virtqueue-size rx))
          (let ((at (+ (virtqueue-desc rx) (* 16 i))))
            (ml-phys-write-64 at (aref (receive-pages net) i))
            (ml-phys-write-32 (+ at 8) 4096)
            (ml-phys-write-16 (+ at 12) 2)
            (ml-phys-write-16 (+ at 14) 0))
          (post-event-buffer rx i))
        (setf (virtqueue-free rx) nil)
        (driver-ok tr)
        (mmio-write (virtqueue-notify rx) 16 0)
        (setf (network-mac net) (coerce (loop for i below 6 collect (device-config-read tr i 8)) '(vector (unsigned-byte 8))))
        (publish-ethernet net "VirtIO Ethernet" t)
        t))))

(defun publish-ethernet (net product builtin)
  (loop for (k v) on (list "IOMACAddress" (network-mac net) "IOMaxPacketSize" 1518 "IOMinPacketSize" 64
                           "IOLinkStatus" 3 "Product Name" product "IOModel" product)
        by #'cddr do (set-property net k v))
  (let ((en (make-instance 'io-ethernet-interface :name (format nil "en~d" *interface-units*))))
    (loop for (k v) on (list "BSD Name" (entry-name en) "IOInterfaceNamePrefix" "en" "IOInterfaceUnit" *interface-units*
                             "IOMaxTransferUnit" 1500 "IOMediaAddressLength" 6 "IOMediaHeaderLength" 14
                             "IOInterfaceType" 6 "IOBuiltin" builtin "IOPrimaryInterface" (zerop *interface-units*))
          by #'cddr do (set-property en k v))
    (incf *interface-units*)
    (attach en net)))

(defmethod network-send ((net virtio-network) frame)
  (sb-thread:with-mutex ((network-lock net))
    (let ((page (send-page net)))
      (dotimes (i +net-header+) (ml-phys-write-8 (+ page i) 0))
      (copy-to-phys frame 0 (+ page +net-header+) (length frame))
      (virtqueue-run (transmit-queue net) (list (list page (+ +net-header+ (length frame)) nil)))
      (length frame))))

(defmethod network-receive ((net virtio-network))
  (sb-thread:with-mutex ((network-lock net))
    (let* ((q (receive-queue net)) (size (virtqueue-size q)) (frames nil))
      (loop until (= (ml-phys-read-16 (+ (virtqueue-used q) 2)) (virtqueue-last-used q))
            do (sb-thread:barrier (:read))
               (let* ((slot (+ (virtqueue-used q) 4 (* 8 (mod (virtqueue-last-used q) size))))
                      (id (ml-phys-read-32 slot))
                      (length (- (ml-phys-read-32 (+ slot 4)) +net-header+))
                      (frame (make-array (max 0 length) :element-type '(unsigned-byte 8))))
                 (copy-from-phys (+ (aref (receive-pages net) id) +net-header+) frame 0 (length frame))
                 (push frame frames)
                 (setf (virtqueue-last-used q) (ldb (byte 16 0) (1+ (virtqueue-last-used q))))
                 (post-event-buffer q id)))
      (when frames (mmio-write (virtqueue-notify q) 16 0))
      (nreverse frames))))

(defmethod interrupt-vector ((net virtio-network)) (virtqueue-vector (receive-queue net)))

(pushnew 'forget-hardware sb-ext:*save-hooks*)

(defun forget-hardware ()
  (setf *registry-root* nil *bsd-units* 0 *interface-units* 0
        *free-vectors* (loop for v from #x30 below +keyboard-vector+ collect v)))
