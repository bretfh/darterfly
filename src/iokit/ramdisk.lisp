(in-package #:finch/iokit)

(defconstant +root-image-start+ 1576)
(defconstant +root-image-size+ 1584)

(define-io-class io-ram-block-storage-device "IORAMBlockStorageDevice" (io-block-storage-device)
  ((base :initarg :base :reader ram-base)
   (block-count :initarg :block-count :accessor block-count)))

(defun root-image ()
  (let* ((args (sb-sys:int-sap (boot-args)))
         (start (sb-sys:sap-ref-64 args +root-image-start+))
         (size (sb-sys:sap-ref-64 args +root-image-size+)))
    (when (and (plusp start) (plusp size))
      (values (+ start +physmap-base+) size))))

(defmethod block-size ((d io-ram-block-storage-device)) 512)

(defmethod read-blocks ((d io-ram-block-storage-device) lba count)
  (let ((vector (make-array (* count 512) :element-type '(unsigned-byte 8))))
    (sb-sys:with-pinned-objects (vector)
      (sb-kernel:system-area-ub8-copy (sb-sys:int-sap (+ (ram-base d) (* lba 512))) 0 (sb-sys:vector-sap vector) 0 (* count 512)))
    vector))

(defmethod write-blocks ((d io-ram-block-storage-device) lba vector)
  (sb-sys:with-pinned-objects (vector)
    (sb-kernel:system-area-ub8-copy (sb-sys:vector-sap vector) 0 (sb-sys:int-sap (+ (ram-base d) (* lba 512))) 0 (length vector)))
  (floor (length vector) 512))

(defmethod flush-blocks ((d io-ram-block-storage-device)) t)

(defun start-root-image (parent)
  (multiple-value-bind (base size) (root-image)
    (when base
      (register-service (attach (make-instance 'io-ram-block-storage-device :name "RAMDisk" :base base
                                                                            :block-count (floor size 512))
                                parent)))))
