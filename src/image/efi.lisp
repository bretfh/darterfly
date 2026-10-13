(in-package #:finch/image)

(defun source (name)
  (uiop:native-namestring (asdf:system-relative-pathname :finch name)))

(defun run (&rest args)
  (multiple-value-bind (out err code)
      (uiop:run-program args :output :string :error-output :output :ignore-error-status t)
    (declare (ignore err))
    (unless (zerop code)
      (error "~a failed:~%~a" (first args) out))
    out))

(defun boot-efi ()
  (let ((object (build-path "efi/boot.o"))
        (out (build-path "efi/boot.efi")))
    (ensure-directories-exist object)
    (run "clang" "-target" "x86_64-unknown-windows" "-ffreestanding" "-fshort-wchar" "-mno-red-zone"
         "-fno-stack-protector" "-fno-builtin" "-nostdlib" "-O2" "-Wall"
         "-c" (source "src/boot/boot.c") "-o" (uiop:native-namestring object))
    (run "lld-link" "/subsystem:efi_application" "/entry:efi_main" "/nodefaultlib"
         (format nil "/out:~a" (uiop:native-namestring out)) (uiop:native-namestring object))
    out))

(defparameter *kernel-sources*
  '("src/osfmk/x86_64/start.s" "src/osfmk/i386/i386_init.c" "src/osfmk/kern/printf.c"
    "src/pexpert/i386/pe_serial.c" "src/pexpert/i386/pe_init.c"))

(defun mach-kernel ()
  (let ((objects
          (loop :for name :in *kernel-sources*
                :for object := (build-path (format nil "kernel/~a.o" (pathname-name name)))
                :do (ensure-directories-exist object)
                    (run "clang" "-target" "x86_64-unknown-none-elf" "-ffreestanding" "-mno-red-zone"
                         "-fPIE" "-fvisibility=hidden" "-fno-stack-protector" "-fno-builtin" "-nostdlib" "-O2" "-Wall"
                         (format nil "-DBUILD_DATE=~s" (date))
                         "-c" (source name) "-o" (uiop:native-namestring object))
                :collect (uiop:native-namestring object)))
        (out (build-path "kernel/kernel")))
    (apply #'run "ld.lld" "-T" (source "src/osfmk/x86_64/kernel.ld") "-nostdlib" "-pie" "--no-dynamic-linker"
           "-o" (uiop:native-namestring out) objects)
    out))

(defun boot-plist (boot-args)
  (let ((d (make-hash-table :test 'equal)))
    (setf (gethash "Kernel Flags" d) boot-args)
    d))

(defun esp (&key (boot-args ""))
  (let ((root (build-path "esp/")))
    (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore)
    (flet ((put (from to)
             (let ((path (merge-pathnames to root)))
               (ensure-directories-exist path)
               (uiop:copy-file from path))))
      (let ((efi (boot-efi)))
        (put efi "EFI/BOOT/BOOTX64.EFI")
        (put efi "System/Library/CoreServices/boot.efi"))
      (put (mach-kernel) "System/Library/Kernels/kernel"))
    (let ((plist (merge-pathnames "Library/Preferences/SystemConfiguration/com.apple.Boot.plist" root)))
      (ensure-directories-exist plist)
      (finch/plist:write-plist (boot-plist boot-args) plist))
    root))

(defun firmware (name)
  (format nil "~a/share/firmware/~a" (uiop:getenv "GUIX_ENVIRONMENT") name))

(defun bare-qemu (esp)
  (let ((vars (build-path "OVMF_VARS.fd")))
    (unless (probe-file vars)
      (uiop:copy-file (firmware "ovmf_vars_x64.bin") vars)
      (run "chmod" "u+w" (uiop:native-namestring vars)))
    (list "qemu-system-x86_64" "-enable-kvm" "-cpu" "host" "-m" "4096" "-smp" "4"
          "-machine" "q35"
          "-drive" (format nil "if=pflash,format=raw,readonly=on,file=~a" (firmware "ovmf_code_x64.bin"))
          "-drive" (format nil "if=pflash,format=raw,file=~a" (uiop:native-namestring vars))
          "-drive" (format nil "if=none,id=esp,format=raw,snapshot=on,file=fat:~a" (uiop:native-namestring esp))
          "-device" "virtio-blk-pci,drive=esp"
          "-device" "isa-debug-exit,iobase=0xf4,iosize=0x04"
          "-monitor" (format nil "unix:~a,server=on,wait=off" (monitor-path))
          "-qmp" (format nil "unix:~a,server=on,wait=off" (qmp-path))
          "-display" "none" "-serial" "stdio" "-no-reboot")))

(defun bare-console (&key (boot-args ""))
  (console :args (bare-qemu (esp :boot-args boot-args))))
