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

(defun freestanding ()
  (list "-nostdinc" "-isystem"
        (format nil "~a/include" (string-trim '(#\Newline) (run "clang" "-print-resource-dir")))))

(defun boot-efi ()
  (let ((object (build-path "efi/boot.o"))
        (out (build-path "efi/boot.efi")))
    (ensure-directories-exist object)
    (apply #'run "clang" "-target" "x86_64-unknown-windows" "-ffreestanding" "-fshort-wchar" "-mno-red-zone"
         "-fno-stack-protector" "-fno-builtin" "-nostdlib" "-O2" "-Wall"
         "-c" (source "src/boot/boot.c") "-o" (uiop:native-namestring object) (freestanding))
    (run "lld-link" "/subsystem:efi_application" "/entry:efi_main" "/nodefaultlib"
         (format nil "/out:~a" (uiop:native-namestring out)) (uiop:native-namestring object))
    out))

(defparameter *kernel-sources*
  '("src/osfmk/x86_64/start.s" "src/osfmk/x86_64/idt64.s" "src/osfmk/i386/i386_init.c"
    "src/osfmk/i386/mp_desc.c" "src/osfmk/i386/pmap.c" "src/osfmk/i386/trap.c" "src/osfmk/i386/rtclock.c"
    "src/osfmk/kern/printf.c" "src/osfmk/kern/debug.c" "src/osfmk/kern/kalloc.c"
    "src/osfmk/vm/vm_resident.c" "src/osfmk/vm/vm_map.c"
    "src/osfmk/i386/lapic.c" "src/osfmk/kern/sched_prim.c" "src/osfmk/x86_64/cswitch.s"
    "src/bsd/kern/kern_sig.c"
    "src/bsd/dev/i386/systemcalls.c" "src/bsd/dev/i386/unix_signal.c"
    "src/pexpert/i386/pe_serial.c" "src/pexpert/i386/pe_init.c" "src/osfmk/x86_64/loose_ends.c"))

(defparameter *libsa-sources*
  '("syscall.c" "signal.c" "string.c" "stdio.c" "stdlib.c" "unistd.c" "time.c" "math.c" "misc.c"
    "setjmp.s" "start.c" "pthread.c" "mfs.c"))

(defun compile-objects (sources dir flags)
  (loop :for name :in sources
        :for object := (build-path (format nil "~a/~a.o" dir (pathname-name name)))
        :do (ensure-directories-exist object)
            (apply #'run "clang" (append flags (list "-c" name "-o" (uiop:native-namestring object))))
        :collect (uiop:native-namestring object)))

(defun kernel-object ()
  (let ((out (uiop:native-namestring (build-path "kernel.o"))))
    (apply #'run "ld.lld" "-r" "-o" out (kernel-objects))
    (run "llvm-objcopy" "--keep-global-symbol=_start" out)
    out))

(defun kernel-objects ()
  (compile-objects (mapcar #'source *kernel-sources*) "kernel"
                   (append (list "-target" "x86_64-unknown-none-elf" "-ffreestanding" "-mno-red-zone"
                                 "-mcmodel=kernel" "-fno-pie" "-fno-stack-protector" "-fno-builtin"
                                 "-mno-sse" "-mno-sse2" "-mno-mmx" "-mno-80387" "-nostdlib" "-O2" "-Wall"
                                 (format nil "-DBUILD_DATE=~s" (date)))
                           (freestanding))))

(defun libsa-objects ()
  (compile-objects (mapcar (lambda (f) (source (concatenate 'string "src/libsa/" f))) *libsa-sources*) "libsa"
                   (append (runtime-flags) (list "-fno-builtin" "-fno-math-errno" "-I" (source "src/libsa")))))

(defun finch-sources ()
  (mapcar #'source '("src/mach/" "src/bsd/" "src/plist/" "src/macho/" "src/dyld/" "src/objc/" "src/mig/"
                     "src/server/" "src/ca/" "src/xpc/" "src/launchd/" "src/shell/" "src/io/" "src/text/"
                     "src/imageio/" "src/kit/" "src/apps/" "src/kernel/" "src/tahoe/" "tests/" "src/image/")))

(defun finch-core ()
  (let ((core (build-path "finch.core")))
    (unless (and (probe-file core) (> (file-write-date core) (newest (finch-sources))))
      (run "sh" "-c"
           (format nil "CL_SOURCE_REGISTRY=\"~a//:$GUIX_ENVIRONMENT/share/common-lisp//\" ASDF_OUTPUT_TRANSLATIONS=\"/:$HOME/.cache/common-lisp/finch-mt/\" ~a --non-interactive --no-userinit --load ~a ~a"
                   (string-right-trim "/" (source ""))
                   (uiop:native-namestring (merge-pathnames "run-sbcl.sh" (sbcl-tree)))
                   (source "src/image/finch-core.lisp")
                   (uiop:native-namestring core))))
    core))

(defun split-core ()
  (let* ((core (finch-core))
         (asm (build-path "core/lisp.s"))
         (object (build-path "core/lisp.o"))
         (data (build-path "core/lisp-core.o")))
    (ensure-directories-exist asm)
    (unless (and (probe-file object) (> (file-write-date object) (file-write-date core)))
      (run (uiop:native-namestring (merge-pathnames "run-sbcl.sh" (sbcl-tree)))
           "--script" (uiop:native-namestring (merge-pathnames "tools-for-build/elftool.lisp" (sbcl-tree)))
           "split" (uiop:native-namestring core) (uiop:native-namestring asm))
      (run "clang" "-target" "x86_64-unknown-none-elf" "-c" (uiop:native-namestring asm)
           "-o" (uiop:native-namestring object)))
    (list (uiop:native-namestring object) (uiop:native-namestring data))))

(defun runtime-objects ()
  (let ((failures (compile-runtime)))
    (when failures
      (error "runtime: ~{~a~^, ~} failed:~%~a" (mapcar #'car failures) (cdr (first failures)))))
  (mapcar (lambda (name) (uiop:native-namestring (merge-pathnames (format nil "~a.o" (pathname-name name)) (runtime-dir))))
          *runtime-sources*))

(defun newest (dirs)
  (loop :for dir :in dirs
        :maximize (loop :for f :in (uiop:directory-files (uiop:ensure-directory-pathname dir))
                        :maximize (file-write-date f))
        :maximize (loop :for sub :in (uiop:subdirectories (uiop:ensure-directory-pathname dir))
                        :maximize (newest (list sub)))))

(defun kernel-inputs ()
  (append (mapcar #'source '("src/osfmk/" "src/bsd/dev/" "src/bsd/kern/" "src/pexpert/" "src/libsa/" "src/sbcl/" "src/image/"))
          (list (merge-pathnames "output/" (sbcl-tree)))
          (finch-sources)))

(defun mach-kernel ()
  (let ((out (build-path "kernel/kernel")))
    (when (and (probe-file out) (> (file-write-date out) (newest (kernel-inputs))))
      (return-from mach-kernel out))
    (apply #'run "ld.lld" "-T" (source "src/osfmk/x86_64/kernel.ld") "-nostdlib" "-static" "--error-limit=0"
           "-o" (uiop:native-namestring out)
           (append (list (kernel-object)) (libsa-objects) (runtime-objects) (split-core)))
    out))

(defun boot-plist (boot-args)
  (let ((d (make-hash-table :test 'equal)))
    (setf (gethash "Kernel Flags" d) boot-args
          (gethash "RAMDisk" d) "/System/Library/RAMDisk/root.cpio")
    d))

(defparameter *ramdisk-files*
  '("tests/ports.txt" "tests/bsd.txt" "tests/bootstrap.txt" "src/tahoe/ports.script" "src/tahoe/bsd.script"))

(defun ramdisk ()
  (write-cpio (build-path "root.cpio")
              (append (list '(:dir "tmp") '(:dir "Users/finch"))
                      (loop :for f :in *ramdisk-files*
                            :collect (list :file (concatenate 'string "finch/" f) (octets (source f)))))))

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
      (put (mach-kernel) "System/Library/Kernels/kernel")
      (put (ramdisk) "System/Library/RAMDisk/root.cpio"))
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
