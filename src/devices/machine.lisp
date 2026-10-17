(defpackage #:darterfly/devices
  (:use #:cl)
  (:nicknames #:devices)
  (:export #:*device-hooks* #:announce #:brightness #:set-brightness #:restore-brightness #:machdep
   #:start-devices #:device-tree #:*registry-root*
   #:entry #:entry-name #:entry-location #:entry-parent #:entry-children
   #:get-property #:set-property #:find-entries
   #:device #:start #:register-service #:*personalities*
   #:pci-node #:config-read-8 #:config-read-16 #:config-read-32
   #:config-write-8 #:config-write-16 #:config-write-32 #:find-pci-capability
   #:map-device-memory-with-index #:memory-map #:map-virtual-address #:map-physical-address #:map-length
   #:virtio-transport #:virtio-pci-transport #:virtio-device-type
   #:virtio-block-storage-device #:block-count #:block-size #:read-blocks #:write-blocks
   #:block-device #:media #:media-read #:media-write #:media-flush #:media-size #:gpt-scheme #:crc32
   #:acpi-table #:vm-page-grab #:ml-io-map #:ml-io-map-wcomb #:boot-arg #:kernel-flags #:boot-video
   #:wait-for-interrupt #:interrupt-vector
   #:virtio-input #:input-events #:input-abs-range
   #:virtio-network #:ethernet-controller #:ecm-status #:battery #:ethernet-interface #:network-send #:network-receive #:network-mac
   #:define-device-class #:add-personality #:personality #:publish-media #:partition-scheme
   #:media-device #:media-base #:next-bsd-unit #:node-class #:media-node))
(in-package #:darterfly/devices)

(defconstant +physmap-base+ #xffff800000000000)

(defun machdep (n &optional (a 0) (b 0))
  (sb-alien:alien-funcall
   (sb-alien:extern-alien "__machdep" (function sb-alien:unsigned-long sb-alien:long sb-alien:unsigned-long sb-alien:unsigned-long))
   n a b))

(defun boot-args () (machdep 8))
(defun vm-page-grab () (machdep 9))
(defun ml-io-map (pa size) (machdep 10 pa size))
(defun ml-io-map-wcomb (pa size) (machdep 14 pa size))

(defun boot-video ()
  (let ((sap (sb-sys:int-sap (machdep 11))))
    (list :row-bytes (sb-sys:sap-ref-32 sap 4) :width (sb-sys:sap-ref-32 sap 8) :height (sb-sys:sap-ref-32 sap 12)
          :depth (sb-sys:sap-ref-32 sap 16) :base (sb-sys:sap-ref-64 sap 48))))

(defun phys-sap (pa) (sb-sys:int-sap (+ +physmap-base+ pa)))
(defun ml-phys-read-8 (pa) (sb-sys:sap-ref-8 (phys-sap pa) 0))
(defun ml-phys-read-16 (pa) (sb-sys:sap-ref-16 (phys-sap pa) 0))
(defun ml-phys-read-32 (pa) (sb-sys:sap-ref-32 (phys-sap pa) 0))
(defun ml-phys-read-64 (pa) (sb-sys:sap-ref-64 (phys-sap pa) 0))
(defun ml-phys-write-8 (pa v) (setf (sb-sys:sap-ref-8 (phys-sap pa) 0) v))
(defun ml-phys-write-16 (pa v) (setf (sb-sys:sap-ref-16 (phys-sap pa) 0) v))
(defun ml-phys-write-32 (pa v) (setf (sb-sys:sap-ref-32 (phys-sap pa) 0) v))
(defun ml-phys-write-64 (pa v) (setf (sb-sys:sap-ref-64 (phys-sap pa) 0) v))

(defun ml-phys-string (pa n)
  (map 'string #'code-char (loop for i below n collect (ml-phys-read-8 (+ pa i)))))

(defun io-sap (va) (sb-sys:int-sap va))

(defun mmio-read (va width)
  (let ((sap (io-sap va)))
    (ecase width (8 (sb-sys:sap-ref-8 sap 0)) (16 (sb-sys:sap-ref-16 sap 0)) (32 (sb-sys:sap-ref-32 sap 0)))))

(defun mmio-write (va width value)
  (let ((sap (io-sap va)))
    (ecase width
      (8 (setf (sb-sys:sap-ref-8 sap 0) value))
      (16 (setf (sb-sys:sap-ref-16 sap 0) value))
      (32 (setf (sb-sys:sap-ref-32 sap 0) value)))))

(defun ml-get-apicid () (machdep 13))

(defun kernel-flags ()
  (let ((sap (sb-sys:sap+ (sb-sys:int-sap (boot-args)) 8)))
    (map 'string #'code-char (loop for i below 1024 for c = (sb-sys:sap-ref-8 sap i) until (zerop c) collect c))))

(defun boot-arg (name)
  (dolist (word (uiop:split-string (kernel-flags) :separator " "))
    (let ((eq (position #\= word)))
      (when (string= name (subseq word 0 (or eq (length word))))
        (return (if eq (subseq word (1+ eq)) t))))))
