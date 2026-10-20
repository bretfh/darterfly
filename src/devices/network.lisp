(in-package #:darterfly/devices)

(defconstant +net-header+ 12)
(defconstant +receive-buffers+ 32)

(define-device-class ethernet-controller "EthernetController" (device))

(defgeneric network-send (net frame))
(defgeneric network-receive (net))

(define-device-class virtio-network "VirtIONetwork" (ethernet-controller)
  ((transport :accessor transport)
   (receive :accessor receive-queue)
   (transmit :accessor transmit-queue)
   (pages :accessor receive-pages)
   (send-page :accessor send-page)
   (send-pages :initform nil :accessor network-send-pages)
   (sent :initform 0 :accessor network-sent)
   (completed :initform 0 :accessor network-completed)
   (reset-dropped :initform 0 :accessor network-reset-dropped)
   (high-water :initform 0 :accessor network-high-water)
   (mac :accessor network-mac)
   (lock :initform (sb-thread:make-mutex :name "virtio-net") :reader network-lock)))

(define-device-class ethernet-interface "EthernetInterface" (device))

(add-personality "Class" "VirtIONetwork" "ProviderClass" "VirtIOTransport"
                 "VirtIOPrimaryMatch" "0x00011af4")

(defconstant +virtio-net-f-mac+ (ash 1 5))



(defmethod start ((net virtio-network) (tr virtio-transport))
  (setf (transport net) tr)
  (let ((wanted (logior +virtio-f-version-1+ +virtio-net-f-mac+)))
    (when (and (= wanted (logand wanted (device-features tr))) (set-driver-features tr wanted))
      (let ((rx (setup-queue tr 0 +receive-buffers+))
            (tx (setup-queue tr 1 64))
            (pages (loop repeat +receive-buffers+ collect (vm-page-grab))))
        (setf (receive-queue net) rx (transmit-queue net) tx (receive-pages net) (coerce pages 'vector)
              (send-page net) (vm-page-grab))
        (post-buffers rx (lambda (i) (aref (receive-pages net) i)) 4096)
        (driver-ok tr)
        (mmio-write (virtqueue-notify rx) 16 0)
        (setf (network-mac net) (coerce (loop for i below 6 collect (device-config-read tr i 8)) '(vector (unsigned-byte 8))))
        (publish-ethernet net "VirtIO Ethernet" t)
        t))))

(defun publish-ethernet (net product builtin)
  (loop for (k v) on (list "MACAddress" (network-mac net) "MaxPacketSize" 1518 "MinPacketSize" 64
                           "LinkStatus" 3 "Product Name" product "Model" product)
        by #'cddr do (set-property net k v))
  (let ((en (make-instance 'ethernet-interface :name (format nil "en~d" *interface-units*))))
    (loop for (k v) on (list "BSD Name" (entry-name en) "InterfaceNamePrefix" "en" "InterfaceUnit" *interface-units*
                             "MaxTransferUnit" 1500 "MediaAddressLength" 6 "MediaHeaderLength" 14
                             "InterfaceType" 6 "Builtin" builtin "PrimaryInterface" (zerop *interface-units*))
          by #'cddr do (set-property en k v))
    (incf *interface-units*)
    (attach en net)))

(defun network-reap-transmit (net)
  ;; NETWORK-LOCK protects TX ownership as well as RX/reset. Completion waits
  ;; never hold it. Each descriptor owns one DMA page until its used entry.
  (let* ((q (transmit-queue net)) (size (virtqueue-size q)))
    (loop until (= (ml-phys-read-16 (+ (virtqueue-used q) 2)) (virtqueue-last-used q))
          do (sb-thread:barrier (:read))
             (let* ((slot (+ (virtqueue-used q) 4 (* 8 (mod (virtqueue-last-used q) size))))
                    (id (ml-phys-read-32 slot)))
               (unless (and (< id size) (not (member id (virtqueue-free q))))
                 (error "virtio-net: invalid TX completion ~d" id))
               (sb-sys:without-interrupts
                 (push id (virtqueue-free q))
                 (incf (network-completed net))
                 (setf (virtqueue-last-used q) (ldb (byte 16 0) (1+ (virtqueue-last-used q)))))))))

(defun network-ensure-send-pages (net)
  (unless (network-send-pages net)
    (setf (network-send-pages net)
          (coerce (cons (send-page net)
                        (loop repeat (1- (virtqueue-size (transmit-queue net))) collect (vm-page-grab)))
                  'vector))))

(defmethod network-send ((net virtio-network) frame)
  (unless (<= (length frame) (- 4096 +net-header+)) (error "virtio-net: frame too large"))
  (let ((deadline (+ (get-internal-real-time) (* 2 internal-time-units-per-second))))
    (loop
      (sb-thread:with-mutex ((network-lock net))
        (network-reap-transmit net)
        (network-ensure-send-pages net)
        (let* ((q (transmit-queue net)) (id (first (virtqueue-free q))))
          (when id
            (let ((page (aref (network-send-pages net) id))
                  (descriptor (+ (virtqueue-desc q) (* id 16)))
                  (idx (ml-phys-read-16 (+ (virtqueue-avail q) 2))))
              (dotimes (i +net-header+) (ml-phys-write-8 (+ page i) 0))
              (copy-to-phys frame 0 (+ page +net-header+) (length frame))
              (ml-phys-write-64 descriptor page)
              (ml-phys-write-32 (+ descriptor 8) (+ +net-header+ (length frame)))
              (ml-phys-write-16 (+ descriptor 12) 0)
              (ml-phys-write-16 (+ descriptor 14) 0)
              (sb-sys:without-interrupts
                (pop (virtqueue-free q))
                (incf (network-sent net))
                (setf (network-high-water net)
                      (max (network-high-water net) (- (virtqueue-size q) (length (virtqueue-free q)))))
                (ml-phys-write-16 (+ (virtqueue-avail q) 4 (* 2 (mod idx (virtqueue-size q)))) id)
                (sb-thread:barrier (:write))
                (ml-phys-write-16 (+ (virtqueue-avail q) 2) (ldb (byte 16 0) (1+ idx)))
                (mmio-write (virtqueue-notify q) 16 (virtqueue-index q)))
              (return-from network-send (length frame))))))
      (when (> (get-internal-real-time) deadline) (error 'ethernet-transmit-stalled))
      (let ((vector (virtqueue-vector (transmit-queue net))))
        (if vector (wait-for-interrupt (list vector) 0.01) (sb-thread:thread-yield))))))

(defmethod network-receive ((net virtio-network))
  (sb-thread:with-mutex ((network-lock net))
    (network-reap-transmit net)
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

(defmethod suspend ((net virtio-network)) (sb-thread:grab-mutex (network-lock net)))

(defmethod wake ((net virtio-network))
  (when (sb-thread:holding-mutex-p (network-lock net))
    (unwind-protect
         (let ((rx (receive-queue net)))
           ;; Reset acknowledgement ends device ownership of outstanding TX.
           ;; TCP retains unacknowledged segments for retransmission.
           (let* ((q (transmit-queue net))
                  (outstanding (- (virtqueue-size q) (length (virtqueue-free q)))))
             (restart-transport (transport net))
             (incf (network-reset-dropped net) outstanding))
           (post-buffers rx (lambda (i) (aref (receive-pages net) i)) 4096)
           (driver-ok (transport net))
           (mmio-write (virtqueue-notify rx) 16 0))
      (sb-thread:release-mutex (network-lock net)))))

(defmethod interrupt-vector ((net virtio-network)) (virtqueue-vector (receive-queue net)))

(pushnew 'forget-hardware sb-ext:*save-hooks*)

(defun forget-hardware ()
  (setf *registry-root* nil *bsd-units* 0 *interface-units* 0
        *free-vectors* (loop for v from #x30 below +keyboard-vector+ collect v)))

(defgeneric network-io-status (net)
  (:method (net) (declare (ignore net)) nil))

(defmethod network-io-status ((net virtio-network))
  (if (sb-thread:grab-mutex (network-lock net) :waitp nil)
      (unwind-protect
           (list :submitted (network-sent net) :completed (network-completed net)
                 :reset-dropped (network-reset-dropped net) :high-water (network-high-water net)
                 :pending (- (virtqueue-size (transmit-queue net))
                             (length (virtqueue-free (transmit-queue net)))))
        (sb-thread:release-mutex (network-lock net)))
      (list :busy t)))
