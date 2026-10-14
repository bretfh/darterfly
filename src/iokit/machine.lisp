(defpackage #:finch/iokit
  (:use #:cl)
  (:nicknames #:iokit)
  (:export
   #:start-iokit #:ioreg #:*registry-root*
   #:io-registry-entry #:entry-name #:entry-location #:entry-parent #:entry-children
   #:get-property #:set-property #:find-entries
   #:io-service #:start #:register-service #:*personalities*
   #:io-pci-device #:config-read-8 #:config-read-16 #:config-read-32
   #:config-write-8 #:config-write-16 #:config-write-32 #:find-pci-capability
   #:map-device-memory-with-index #:io-memory-map #:map-virtual-address #:map-physical-address #:map-length
   #:apple-virtio-transport #:apple-virtio-pci-transport #:virtio-device-type
   #:apple-virtio-block-storage-device #:block-count #:block-size #:read-blocks #:write-blocks
   #:io-block-storage-device #:io-media #:media-read #:media-write #:media-size #:io-guid-partition-scheme #:crc32
   #:acpi-table #:vm-page-grab #:ml-io-map
   #:define-io-class #:add-personality #:personality #:publish-media #:io-partition-scheme
   #:media-device #:media-base #:next-bsd-unit #:bsd-client-class #:io-media-bsd-client))
(in-package #:finch/iokit)

(defconstant +physmap-base+ #xffff800000000000)

(defun machdep (n &optional (a 0) (b 0))
  (sb-alien:alien-funcall
   (sb-alien:extern-alien "__machdep" (function sb-alien:unsigned-long sb-alien:long sb-alien:unsigned-long sb-alien:unsigned-long))
   n a b))

(defun boot-args () (machdep 8))
(defun vm-page-grab () (machdep 9))
(defun ml-io-map (pa size) (machdep 10 pa size))

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
