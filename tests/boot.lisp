(in-package #:finch/test)

(def-suite boot :in all)
(in-suite boot)

(test boot-efi-starts-the-kernel
  (let ((c (image:bare-console :boot-args "halt")))
    (unwind-protect
         (progn
           (is (image:expect c "finch boot.efi"))
           (is (search "rsdp 0x" (image:expect c "boot-args \"halt\"")))
           (is (image:expect c "finch Kernel Version"))
           (is (image:expect c "boot_args: Revision 1 Version 2 efiMode 64"))
           (is (search "kslide 0x" (image:expect c "memory:")))
           (is (search "MB usable" (image:expect c "video: 1280x800x32")))
           (is (image:expect c (format nil "~%halt"))))
      (image:finish c 5))))
