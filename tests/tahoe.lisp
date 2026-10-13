(in-package #:finch/test)

(def-suite tahoe :in all)
(in-suite tahoe)

(test opencore-config-validates
  (let ((tahoe:*home* (uiop:ensure-directory-pathname (merge-pathnames "tahoe/" (scratch)))))
    (let* ((esp (tahoe:esp))
           (oc (merge-pathnames "EFI/OC/" esp))
           (report (uiop:run-program (list "ocvalidate" (uiop:native-namestring (merge-pathnames "config.plist" oc)))
                                    :output :string :error-output :output :ignore-error-status t)))
      (is (search "No issues found" report) "~a" report)
      (dolist (f '("OpenCore.efi" "ACPI/SSDT-EC-USBX.aml" "Drivers/OpenRuntime.efi"
                   "Drivers/OpenHfsPlus.efi" "Kexts/Lilu.kext/Contents/MacOS/Lilu"))
        (is-true (probe-file (merge-pathnames f oc)) "~a missing" f))
      (is-true (probe-file (merge-pathnames "EFI/BOOT/BOOTx64.efi" esp))))))

(test opencore-config-carries-the-guest
  (let ((c (tahoe:config)))
    (flet ((at (&rest path) (reduce (lambda (h k) (gethash k h)) path :initial-value c)))
      (is (string= tahoe:*product* (at "PlatformInfo" "Generic" "SystemProductName")))
      (is (equalp #(#xef #x0f 0 0)
                  (at "NVRAM" "Add" "7C436110-AB2A-4BBB-A880-FE41995C9F82" "csr-active-config")))
      (is (equalp '("Lilu.kext" "VirtualSMC.kext" "WhateverGreen.kext")
                  (map 'list (lambda (k) (gethash "BundlePath" k)) (at "Kernel" "Add")))))))
