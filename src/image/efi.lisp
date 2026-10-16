(in-package #:finch/image)

(defun source (name)
  (uiop:native-namestring (asdf:system-relative-pathname :finch name)))

(defun run (&rest args)
  (multiple-value-bind (out err code)
      (uiop:run-program args :output :string :error-output :output :ignore-error-status t :directory (source ""))
    (declare (ignore err))
    (unless (zerop code)
      (error "~a failed:~%~a" (first args) out))
    out))

(defun freestanding ()
  (list "-nostdinc" "-isystem"
        (format nil "~a/include" (string-trim '(#\Newline) (run "clang" "-print-resource-dir")))))

(defun boot-efi ()
  (let ((out (build-path "efi/boot.efi")))
    (ensure-directories-exist out)
    (with-open-file (s out :direction :output :element-type '(unsigned-byte 8) :if-exists :supersede)
      (write-sequence (finch/boot:boot-image) s))
    out))

(defun finch-sources ()
  (cons (source "tests/")
        (remove-if-not (lambda (dir) (uiop:directory-files dir "*.lisp"))
                       (uiop:subdirectories (source "src/")))))

(defun finch-core ()
  (let ((core (build-path "finch.core")))
    (unless (and (probe-file core)
                 (> (file-write-date core) (max (newest (finch-sources))
                                                (file-write-date (merge-pathnames "output/sbcl.core" (sbcl-tree))))))
      (run "sh" "-c"
           (format nil "CL_SOURCE_REGISTRY=\"~a//:$GUIX_ENVIRONMENT/share/common-lisp//\" ASDF_OUTPUT_TRANSLATIONS=\"/:$HOME/.cache/common-lisp/finch-mt/\" ~a --non-interactive --no-userinit --load ~a ~a"
                   (string-right-trim "/" (source ""))
                   (uiop:native-namestring (merge-pathnames "run-sbcl.sh" (sbcl-tree)))
                   (source "src/image/finch-core.lisp")
                   (uiop:native-namestring core))))
    core))

(defun host-units () (finch/cc:units :libtcc1 (eq *c-compiler* :tcc)))

(defun unit-object (unit) (build-path (format nil "~a/~a" (object-dir "objects") (getf unit :name))))

(defun unit-clang-flags (unit)
  (let ((group (subseq (getf unit :name) 0 (position #\/ (getf unit :name)))))
    (append (runtime-flags)
            (cond ((string= group "libsa") (list "-fno-builtin" "-fno-math-errno"))
                  ((string= group "libtcc") (list "-fno-builtin"))))))

(defun c-objects ()
  (runtime-tree)
  (libtcc-tree)
  (let ((failures
          (loop :for unit :in (host-units)
                :for out := (multiple-value-bind (out err code)
                                (uiop:run-program (c-compile (getf unit :source) (unit-object unit)
                                                             :includes (getf unit :includes) :defines (getf unit :defines)
                                                             :compat (getf unit :compat t) :clang-flags (unit-clang-flags unit))
                                                  :output :string :error-output :output :ignore-error-status t
                                                  :directory (source ""))
                              (declare (ignore err))
                              (unless (zerop code) out))
                :when out :collect (cons (getf unit :name) out))))
    (when failures
      (error "C: ~{~a~^, ~} failed:~%~a" (mapcar #'car failures) (cdr (first failures))))))

(defun newest (dirs)
  (loop :for dir :in dirs
        :maximize (loop :for f :in (uiop:directory-files (uiop:ensure-directory-pathname dir))
                        :maximize (file-write-date f))
        :maximize (loop :for sub :in (uiop:subdirectories (uiop:ensure-directory-pathname dir))
                        :maximize (newest (list sub)))))

(defun kernel-inputs ()
  (append (mapcar #'source '("src/osfmk/" "src/bsd/dev/" "src/bsd/kern/" "src/pexpert/" "src/libsa/" "src/sbcl/" "src/image/"
                                     "src/asm/" "src/low/" "src/link/" "src/boot/" "src/cc/" "src/install/"))
          (list (merge-pathnames "output/" (sbcl-tree)))))

(defun user-objects ()
  (mapcar (lambda (unit) (list (getf unit :name) (unit-object unit))) (host-units)))

(defun mach-kernel ()
  (let ((out (build-path (if (eq *c-compiler* :clang) "kernel/kernel" "kernel/kernel-tcc"))))
    (when (and (probe-file out) (> (file-write-date out) (newest (kernel-inputs))))
      (return-from mach-kernel out))
    (c-objects)
    (let ((image (finch/install:kernel-image (loop :for (name path) :in (user-objects) :collect (cons name (octets path))))))
      (ensure-directories-exist out)
      (with-open-file (s out :direction :output :element-type '(unsigned-byte 8) :if-exists :supersede)
        (write-sequence image s)))
    out))

(defun compiler-entries ()
  (flet ((sources (file) (member (pathname-type file) '("c" "h" "S" "inc" "def") :test #'string=)))
    (append (tree-entries (build-path "runtime/") "usr/src/finch/build/runtime" :keep #'sources)
            (tree-entries (libtcc-tree) "usr/src/finch/build/tcc/finch-src")
            (tree-entries (merge-pathnames "lib/" (tcc-stage 2)) "usr/src/finch/build/tcc/stage2/lib" :keep #'sources)
            (tree-entries (merge-pathnames "include/" (tcc-stage 2)) "usr/lib/tcc/include")
            (list (list :file "usr/lib/tcc/libc.a" (text (format nil "!<arch>~%")))
                  (list :file "usr/lib/tcc/libtcc1.a" (text (format nil "!<arch>~%")))))))

(defun object-entries ()
  (mach-kernel)
  (let ((objects (user-objects)))
    (cons (list :file "usr/lib/finch/objects/objects" (text (format nil "~{~a~%~}" (mapcar #'first objects))))
          (loop :for (name path) :in objects
                :collect (list :file (concatenate 'string "usr/lib/finch/objects/" name) (octets path))))))

(defun boot-plist (boot-args)
  (let ((d (make-hash-table :test 'equal)))
    (setf (gethash "Kernel Flags" d) (format nil "~a -- --core /System/Library/Kernels/finch.core" boot-args)
          (gethash "RAMDisk" d) "/System/Library/RAMDisk/root.cpio")
    d))

(defparameter *ramdisk-files*
  '("tests/ports.txt" "tests/bsd.txt" "tests/bootstrap.txt" "src/tahoe/ports.script" "src/tahoe/bsd.script" "tests/apfs-files.txt"))

(defun ramdisk ()
  (write-cpio (build-path "root.cpio")
              (append (list '(:dir "tmp") '(:dir "Users/finch"))
                      (loop :for f :in *ramdisk-files*
                            :collect (list :file (concatenate 'string "finch/" f) (octets (source f)))))))

(defun desktop-entries ()
  (append (loop :for (path program) :in *programs*
                :collect (list :file path (text (format nil "#!finch ~a~%" program)) #o755))
          (desktop-jobs) (fonts) (icons)))

(defun contribs ()
  (loop :for file :in (append (directory (merge-pathnames "obj/sbcl-home/contrib/*.fasl" (sbcl-tree)))
                              (directory (merge-pathnames "obj/sbcl-home/contrib/*.asd" (sbcl-tree))))
        :collect (list :file (format nil "usr/lib/sbcl/contrib/~a" (file-namestring file)) (octets file))))

(defun library-entries ()
  (loop :for dir :in (uiop:subdirectories (format nil "~a/share/common-lisp/sbcl/" (uiop:getenv "GUIX_ENVIRONMENT")))
        :append (tree-entries dir (format nil "usr/share/common-lisp/sbcl/~a" (car (last (pathname-directory dir)))))))

(defun certificates ()
  (list (list :file "etc/ssl/certs/ca-certificates.crt"
              (octets (format nil "~a/etc/ssl/certs/ca-certificates.crt" (uiop:getenv "GUIX_ENVIRONMENT"))))))

(defun root-entries ()
  (let ((files (append (loop :for f :in *ramdisk-files*
                             :collect (list :file (concatenate 'string "finch/" f) (octets (source f))))
                       (desktop-entries)
                       (contribs)
                       (certificates)
                       (library-entries)
                       (object-entries)
                       (compiler-entries)
                       (tree-entries (asdf:system-relative-pathname :finch "") "usr/src/finch"
                                     :skip '(".git" "build" "tahoe"))))
        (dirs (list "tmp" "Users" "Users/finch" "dev" "Volumes" "System" "System/Library" "System/Library/Kernels")))
    (dolist (f files)
      (let ((path (second f)))
        (loop for slash = (position #\/ path) then (position #\/ path :start (1+ slash))
              while slash
              do (pushnew (subseq path 0 slash) dirs :test #'string=))))
    (append (mapcar (lambda (d) (list :dir d))
                    (sort (remove-duplicates dirs :test #'string=) #'< :key (lambda (d) (count #\/ d))))
            files)))

(defun sbcl-source-entries ()
  (let ((tree (sbcl-tree)))
    (append (tree-entries (format nil "~a/share/sbcl-source/" (uiop:getenv "GUIX_ENVIRONMENT")) "usr/src/sbcl"
                          :skip '(".git" "version.lisp-expr"))
            (list (list :dir "usr/src/sbcl/output"))
            (loop :for file :in '("version.lisp-expr" "local-target-features.lisp-expr" "output/build-config" "output/build-id.inc"
                                  "output/dynamic-space-size.txt" "output/prefix.def"
                                  "output/stuff-groveled-from-headers.lisp")
                  :collect (list :file (concatenate 'string "usr/src/sbcl/" file) (octets (merge-pathnames file tree)) #o644
                                 (file-time (merge-pathnames file tree)))))))

(defun root-disk (&optional (path (build-path "root.img")) (size (* 128 1048576)) (entries (root-entries)))
  (finch/apfs:newfs path :size size :volume-name "finch HD" :entries entries
                         :container-uuid "F1C40000-0000-4000-8000-000000000001"
                         :volume-uuid "F1C40000-0000-4000-8000-000000000002"))

(defun same-content-p (path octets)
  (let ((attr (ignore-errors (finch/vfs:vfs-stat path))))
    (and attr (= (finch/vfs:vattr-size attr) (length octets))
         (let ((fd (finch/vfs:vfs-open path (list :access :rdonly) 0)))
           (unwind-protect (equalp (finch/vfs:vfs-read fd (length octets)) octets)
             (finch/vfs:vfs-close fd))))))

(defun update-root (path &optional (entries (root-entries)))
  (let ((finch/vfs:*root* nil) (finch/vfs:*mounts* nil))
    (finch/vfs:vfs-mount (finch/vfs:make-ram-node :vdir #o755) "/")
    (finch/vfs:vfs-mkdir "/root" #o755)
    (multiple-value-bind (read write) (finch/apfs:file-store path)
      (finch/apfs:mount-writable read write "/root"))
    (finch/apfs:with-batch
      (update-entries entries))
    path))

(defun update-entries (entries)
  (dolist (entry entries)
    (let ((at (format nil "/root/~a" (second entry))))
      (ecase (first entry)
        (:dir (unless (ignore-errors (finch/vfs:vfs-stat at)) (finch/vfs:vfs-mkdir at #o755)))
        (:file (destructuring-bind (octets &optional (mode #o644) time) (cddr entry)
                 (declare (ignore time))
                 (unless (same-content-p at octets)
                   (let ((fd (finch/vfs:vfs-open at (list :access :wronly :creat t :trunc t) (logand mode #o7777))))
                     (unwind-protect (finch/vfs:vfs-write fd octets)
                       (finch/vfs:vfs-close fd))))))))))

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
      (put (mach-kernel) "EFI/finch/gen-1/kernel")
      (put (finch-core) "EFI/finch/gen-1/finch.core")
      (put (ramdisk) "System/Library/RAMDisk/root.cpio"))
    (with-open-file (s (merge-pathnames "EFI/finch/current" root) :direction :output)
      (write-line "gen-1" s))
    (let ((plist (merge-pathnames "Library/Preferences/SystemConfiguration/com.apple.Boot.plist" root)))
      (ensure-directories-exist plist)
      (finch/plist:write-plist (boot-plist boot-args) plist))
    root))

(defun esp-image (esp &optional (image (build-path "esp.img")))
  (let ((root (uiop:ensure-directory-pathname esp))
        (entries nil))
    (labels ((relative (p) (enough-namestring p root))
             (walk (dir)
               (dolist (sub (uiop:subdirectories dir))
                 (push (list :dir (string-right-trim "/" (relative sub))) entries)
                 (walk sub))
               (dolist (f (uiop:directory-files dir))
                 (push (list :file (relative f)
                             (with-open-file (s f :element-type '(unsigned-byte 8))
                               (let ((v (make-array (file-length s) :element-type '(unsigned-byte 8))))
                                 (read-sequence v s)
                                 v)))
                       entries))))
      (walk root))
    (finch/fat:newfs image :size (* 256 1048576) :label "EFI" :entries (nreverse entries))))

(defun firmware (name)
  (format nil "~a/share/firmware/~a" (uiop:getenv "GUIX_ENVIRONMENT") name))

(defun bare-qemu (esp &optional disks root forwards)
  (append
   (list "qemu-system-x86_64" "-enable-kvm" "-cpu" "host" "-m" "4096" "-smp" "4"
        "-machine" "q35"
        "-drive" (format nil "if=pflash,format=raw,readonly=on,file=~a" (firmware "ovmf_code_x64.bin"))
        "-drive" (format nil "if=pflash,format=raw,snapshot=on,file=~a" (firmware "ovmf_vars_x64.bin"))
        "-drive" (if (equal (pathname-type esp) "img")
                     (format nil "if=none,id=esp,format=raw,file=~a" (uiop:native-namestring esp))
                     (format nil "if=none,id=esp,format=raw,snapshot=on,file=~a" (uiop:native-namestring (esp-image esp))))
        "-device" "virtio-blk-pci,drive=esp,bootindex=0")
   (when root
     (list "-drive" (format nil "if=none,id=root,format=raw,~:[~;snapshot=on,~]file=~a" (eq (car root) :snapshot) (uiop:native-namestring (cdr root)))
           "-device" "virtio-blk-pci,drive=root"))
   (loop for disk in disks for i from 0
         append (list "-drive" (format nil "if=none,id=disk~d,format=raw,file=~a" i (uiop:native-namestring disk))
                      "-device" (format nil "virtio-blk-pci,drive=disk~d" i)))
   (list "-netdev" (format nil "user,id=net0~{,hostfwd=~(~a~)::~d-:~d~}" (loop for (proto host guest) in forwards append (list proto host guest)))
         "-device" "virtio-net-pci,netdev=net0,romfile=")
   (list "-device" "virtio-keyboard-pci" "-device" "virtio-tablet-pci"
         "-device" "isa-debug-exit,iobase=0xf4,iosize=0x04"
        "-monitor" (format nil "unix:~a,server=on,wait=off" (monitor-path))
        "-qmp" (format nil "unix:~a,server=on,wait=off" (qmp-path))
        "-display" "none" "-serial" "stdio" "-no-reboot")))

(defun root-boot-args (boot-args root)
  (if root (format nil "rd=disk2s1 ~a" boot-args) boot-args))

(defun root-drive (root)
  (cond ((null root) nil)
        ((eq root t) (cons :snapshot (root-disk)))
        ((probe-file root) (cons :keep (update-root root)))
        (t (cons :keep (root-disk root)))))

(defun bare-boot (&key (boot-args "") disks (root t))
  (uiop:run-program (substitute "mon:stdio" "stdio" (bare-qemu (esp :boot-args (root-boot-args boot-args root)) disks (root-drive root))
                                :test #'equal)
                    :input :interactive :output :interactive :error-output :interactive :ignore-error-status t)
  (values))

(defun file-time (file) (* 1000000000 (- (file-write-date file) 2208988800)))

(defun tree-entries (from to &key (skip '(".git")) (keep (constantly t)))
  (let ((entries (loop :for parent :in (parents (format nil "/~a" to)) :collect (list :dir parent))))
    (labels ((walk (dir at relative)
               (push (list :dir at) entries)
               (dolist (file (uiop:directory-files dir))
                 (unless (or (member (concatenate 'string relative (file-namestring file)) skip :test #'string=)
                             (not (funcall keep file)))
                   (push (list :file (format nil "~a/~a" at (file-namestring file)) (octets file)
                               (if (logtest #o111 (sb-posix:stat-mode (sb-posix:stat (uiop:native-namestring file)))) #o755 #o644)
                               (file-time file))
                         entries)))
               (dolist (sub (uiop:subdirectories dir))
                 (let ((name (car (last (pathname-directory sub)))))
                   (unless (member (concatenate 'string relative name) skip :test #'string=)
                     (walk sub (format nil "~a/~a" at name) (concatenate 'string relative name "/")))))))
      (walk (uiop:ensure-directory-pathname from) (string-trim "/" to) ""))
    (nreverse entries)))

(defun copy-in (from to &key (disk (build-path "finch-hd.img")) (skip '(".git")))
  (when (in-use-p disk)
    (error "~a is in use by a running finch; quit that one first" (uiop:native-namestring disk)))
  (update-root disk (tree-entries from to :skip skip)))

(defun in-use-p (disk)
  (not (zerop (nth-value 2 (uiop:run-program (list "qemu-io" "-f" "raw" "-c" "quit" (uiop:native-namestring disk))
                                             :ignore-error-status t :output nil :error-output nil)))))

(defun desktop (&key (disk (build-path "finch-hd.img")))
  (when (and (probe-file disk) (in-use-p disk))
    (error "~a is in use by a running finch; quit that one first" (uiop:native-namestring disk)))
  (let ((root (if (probe-file disk) (update-root disk) (root-disk disk (* 1024 1048576))))
        (esp (build-path "desktop/esp/")))
    (uiop:delete-directory-tree esp :validate t :if-does-not-exist :ignore)
    (run "cp" "-a" (uiop:native-namestring (esp :boot-args (root-boot-args "launchd" t)))
         (uiop:native-namestring (ensure-directories-exist (build-path "desktop/"))))
    (uiop:run-program (substitute "gtk,zoom-to-fit=off" "none"
                                  (bare-qemu esp nil (cons :keep root))
                                  :test #'equal)
                      :output :interactive :error-output :interactive :ignore-error-status t)
    (values)))

(defun bare-console (&key (boot-args "") disks (root t) forwards esp)
  (let ((dir (unless (and esp (probe-file esp)) (esp :boot-args (root-boot-args boot-args root)))))
    (console :args (bare-qemu (cond ((null esp) dir)
                                    ((probe-file esp) esp)
                                    (t (esp-image dir esp)))
                              disks (root-drive root) forwards))))
