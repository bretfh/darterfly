(in-package #:finch/io)

(defconstant +sys-finit-module+ 313)
(defconstant +module-init-compressed-file+ 4)

(defparameter *kexts*
  '("kernel/drivers/virtio/virtio_ring.ko.zst"
    "kernel/drivers/virtio/virtio.ko.zst"
    "kernel/drivers/virtio/virtio_pci_legacy_dev.ko.zst"
    "kernel/drivers/virtio/virtio_pci_modern_dev.ko.zst"
    "kernel/drivers/virtio/virtio_pci.ko.zst"
    "kernel/drivers/virtio/virtio_input.ko.zst"
    "kernel/drivers/input/mouse/psmouse.ko.zst"))

(defun modules-dir ()
  (let ((release (string-trim '(#\Newline) (uiop:read-file-string "/proc/sys/kernel/osrelease"))))
    (format nil "/lib/modules/~a/" release)))

(defun kextload (path)
  (let ((fd (sb-posix:open path sb-posix:o-rdonly)))
    (unwind-protect
         (let ((r (sb-alien:alien-funcall
                   (sb-alien:extern-alien "syscall" (function sb-alien:long sb-alien:long sb-alien:int
                                                              sb-alien:c-string sb-alien:int))
                   +sys-finit-module+ fd "" +module-init-compressed-file+)))
           (if (zerop r) t (sb-int:strerror)))
      (sb-posix:close fd))))

(defun load-kexts ()
  (loop :for kext :in *kexts*
        :collect (list (pathname-name (pathname-name kext))
                       (kextload (format nil "~a~a" (modules-dir) kext)))))
