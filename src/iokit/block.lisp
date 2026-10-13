(in-package #:finch/iokit)

(defconstant +virtio-f-version-1+ (ash 1 32))
(defconstant +request-pages+ 8)

(define-io-class apple-virtio-block-storage-device "AppleVirtIOBlockStorageDevice" (io-service)
  ((transport :accessor transport)
   (queue :accessor queue)
   (block-count :accessor block-count)
   (request :accessor request-page)
   (data :accessor data-pages)
   (lock :initform (sb-thread:make-mutex :name "virtio-blk") :reader device-lock)))

(add-personality "IOClass" "AppleVirtIOBlockStorageDevice" "IOProviderClass" "AppleVirtIOTransport"
                 "IOVirtIOPrimaryMatch" "0x00021af4")

(defun block-size (device) (declare (ignore device)) 512)

(defmethod start ((b apple-virtio-block-storage-device) (tr apple-virtio-transport))
  (setf (transport b) tr)
  (when (and (logtest (device-features tr) +virtio-f-version-1+)
             (set-driver-features tr +virtio-f-version-1+))
    (setf (queue b) (setup-queue tr 0)
          (request-page b) (vm-page-grab)
          (data-pages b) (loop repeat +request-pages+ collect (vm-page-grab)))
    (driver-ok tr)
    (setf (block-count b) (device-config-read-64 tr 0))
    (set-property b "Size" (* (block-count b) 512))
    t))

(defun copy-from-phys (pa vector start count)
  (sb-sys:with-pinned-objects (vector)
    (sb-kernel:system-area-ub8-copy (phys-sap pa) 0 (sb-sys:vector-sap vector) start count)))

(defun copy-to-phys (vector start pa count)
  (sb-sys:with-pinned-objects (vector)
    (sb-kernel:system-area-ub8-copy (sb-sys:vector-sap vector) start (phys-sap pa) 0 count)))

(defun block-request (b type lba count vector start)
  (let ((header (request-page b))
        (pages (subseq (data-pages b) 0 (ceiling (* count 512) 4096))))
    (ml-phys-write-32 header type)
    (ml-phys-write-32 (+ header 4) 0)
    (ml-phys-write-64 (+ header 8) lba)
    (ml-phys-write-8 (+ header 16) #xff)
    (when (= type 1)
      (loop for pa in pages for at from start by 4096
            do (copy-to-phys vector at pa (min 4096 (- (+ start (* count 512)) at)))))
    (virtqueue-run (queue b)
                   (append (list (list header 16 nil))
                           (loop for pa in pages for left downfrom (* count 512) by 4096
                                 collect (list pa (min 4096 left) (= type 0)))
                           (list (list (+ header 16) 1 t))))
    (let ((status (ml-phys-read-8 (+ header 16))))
      (unless (zerop status) (error "virtio-blk: request ~d at block ~d failed with status ~d" type lba status)))
    (when (= type 0)
      (loop for pa in pages for at from start by 4096
            do (copy-from-phys pa vector at (min 4096 (- (+ start (* count 512)) at)))))))

(defun read-blocks (b lba count)
  (let ((vector (make-array (* count 512) :element-type '(unsigned-byte 8)))
        (per (* +request-pages+ 8)))
    (sb-thread:with-mutex ((device-lock b))
      (loop for done from 0 below count by per
            do (block-request b 0 (+ lba done) (min per (- count done)) vector (* done 512))))
    vector))

(defun write-blocks (b lba vector)
  (let ((count (floor (length vector) 512))
        (per (* +request-pages+ 8)))
    (sb-thread:with-mutex ((device-lock b))
      (loop for done from 0 below count by per
            do (block-request b 1 (+ lba done) (min per (- count done)) vector (* done 512))))
    count))
