(in-package #:darterfly/image)

(defun source (name)
  (uiop:native-namestring (asdf:system-relative-pathname :darterfly name)))

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
      (write-sequence (darterfly/boot:boot-image) s))
    out))

(defun darterfly-sources ()
  (cons (source "tests/")
        (remove-if-not (lambda (dir) (uiop:directory-files dir "*.lisp"))
                       (uiop:subdirectories (source "src/")))))

(defun darterfly-core ()
  (let ((core (build-path "darterfly.core")))
    (unless (and (probe-file core)
                 (> (file-write-date core) (max (newest (darterfly-sources))
                                                (file-write-date (merge-pathnames "output/sbcl.core" (sbcl-tree))))))
      (run "env"
           (format nil "CL_SOURCE_REGISTRY=~a//:~a/share/common-lisp//"
                   (string-right-trim "/" (source "")) (uiop:getenv "GUIX_ENVIRONMENT"))
           (format nil "ASDF_OUTPUT_TRANSLATIONS=/:~a/"
                   (string-right-trim "/" (uiop:native-namestring (build-path (format nil "fasl/~a/" darterfly/build:*sbcl-version*)))))
           (uiop:native-namestring (merge-pathnames "run-sbcl.sh" (sbcl-tree)))
           "--non-interactive" "--no-userinit" "--no-sysinit" "--load"
           (source "src/image/darterfly-core.lisp") (uiop:native-namestring core)))
    core))

(defun host-units () (darterfly/cc:units :libtcc1 (eq *c-compiler* :tcc)))

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
  (append (mapcar #'source '("src/kern/" "src/bsd/dev/" "src/bsd/kern/" "src/platform/" "src/libsa/" "src/sbcl/" "src/image/"
                                     "src/asm/" "src/low/" "src/link/" "src/boot/" "src/cc/" "src/install/"))
          (list (merge-pathnames "output/" (sbcl-tree)))))

(defun user-objects ()
  (mapcar (lambda (unit) (list (getf unit :name) (unit-object unit))) (host-units)))

(defun kernel-file ()
  (let ((out (build-path (if (eq *c-compiler* :clang) "kernel/kernel" "kernel/kernel-tcc"))))
    (when (and (probe-file out) (> (file-write-date out) (newest (kernel-inputs))))
      (return-from kernel-file out))
    (c-objects)
    (let ((image (darterfly/install:kernel-image (loop :for (name path) :in (user-objects) :collect (cons name (octets path)))
                                                 :date (newest (mapcar #'source '("src/kern/" "src/bsd/dev/" "src/bsd/kern/" "src/platform/"
                                                                                  "src/libsa/" "src/sbcl/" "src/low/" "src/asm/"))))))
      (ensure-directories-exist out)
      (with-open-file (s out :direction :output :element-type '(unsigned-byte 8) :if-exists :supersede)
        (write-sequence image s)))
    out))

(defun compiler-entries ()
  (flet ((sources (file) (member (pathname-type file) '("c" "h" "S" "inc" "def") :test #'string=)))
    (append (tree-entries (build-path "runtime/") "usr/src/darterfly/build/runtime" :keep #'sources)
            (tree-entries (libtcc-tree) "usr/src/darterfly/build/tcc/darterfly-src")
            (tree-entries (merge-pathnames "lib/" (tcc-stage 2)) "usr/src/darterfly/build/tcc/stage2/lib" :keep #'sources)
            (tree-entries (merge-pathnames "include/" (tcc-stage 2)) "usr/lib/tcc/include")
            (list (list :file "usr/lib/tcc/libc.a" (text (format nil "!<arch>~%")))
                  (list :file "usr/lib/tcc/libtcc1.a" (text (format nil "!<arch>~%")))))))

(defun object-entries ()
  (kernel-file)
  (let ((objects (user-objects)))
    (cons (list :file "usr/lib/darterfly/objects/objects" (text (format nil "~{~a~%~}" (mapcar #'first objects))))
          (loop :for (name path) :in objects
                :collect (list :file (concatenate 'string "usr/lib/darterfly/objects/" name) (octets path))))))

(defvar *sbcl-runtime-options* nil
  "Additional SBCL runtime arguments for explicitly sized guest images.")

(defun boot-conf (boot-args &optional root-image)
  (format nil "kernel-flags=~a -- ~{~a ~}--core /System/Library/Kernels/darterfly.core~%ramdisk=/System/Library/RAMDisk/root.cpio~%~@[root-image=~a~%~]"
          boot-args *sbcl-runtime-options* (and root-image "/System/Library/RAMDisk/root.img")))

(defun ramdisk ()
  (write-cpio (build-path "root.cpio") (list '(:dir "tmp") '(:dir "Users/darterfly"))))

(defun desktop-entries ()
  (append (loop :for (path program) :in *programs*
                :collect (list :file path (text (format nil "#!darterfly ~a~%" program)) #o755))
          (desktop-jobs) (fonts) (icons) (startup-artwork)))

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

(defun host-zone ()
  (let* ((link (or (uiop:getenv "TZ") (ignore-errors (sb-posix:readlink "/etc/localtime")) ""))
         (at (search "zoneinfo/" link)))
    (string-left-trim ":" (if at (subseq link (+ at 9)) link))))

(defun zoneinfo ()
  (let* ((dir (format nil "~a/share/zoneinfo/" (uiop:getenv "GUIX_ENVIRONMENT")))
         (zone (host-zone))
         (file (and (plusp (length zone)) (probe-file (concatenate 'string dir zone)))))
    (append (tree-entries dir "usr/share/zoneinfo" :skip '("posix" "right"))
            (list (list :file "etc/localtime" (octets (or file (concatenate 'string dir "UTC"))))))))

(defun ocicl-entries ()
  (tree-entries (format nil "~a/share/ocicl-source/" (uiop:getenv "GUIX_ENVIRONMENT")) "usr/src/ocicl"
                :skip '(".git" ".github" ".githooks" "docs" "releng" "test" "ocicl" "ocicl.old")))

(defparameter *firmware* '("iwlwifi-ty-a0-gf-a0-77.ucode" "iwlwifi-ty-a0-gf-a0.pnvm" "i915/adlp_dmc.bin"))

(defun firmware-entries ()
  (loop :for name :in *firmware*
        :for packed := (format nil "~a/lib/firmware/~a.zst" (uiop:getenv "GUIX_ENVIRONMENT") name)
        :for plain := (build-path (substitute #\- #\/ name))
        :do (uiop:run-program (list "zstd" "-d" "-f" "-q" "-o" (uiop:native-namestring plain) packed))
        :collect (list :file (concatenate 'string "Library/Firmware/" name) (octets plain))))

(defun release-entries ()
  (let ((identity (uiop:getenv "DARTERFLY_RELEASE_IDENTITY")))
    (when identity
      (list (list :file "System/Library/Release/identity.json" (octets identity))))))

(defun nyxt-package-root ()
  (let ((explicit (uiop:getenv "DARTERFLY_NYXT_ROOT")))
    (let ((root (uiop:ensure-directory-pathname
                 (or explicit (merge-pathnames ".cache/darterfly/nyxt/root/"
                                               (user-homedir-pathname))))))
      (cond ((probe-file (merge-pathnames "usr/lib/nyxt/package.sexp" root)) root)
            (explicit (error "No Nyxt package at ~a; run make nyxt-package" root))))))

(defvar *include-browser* nil)

(defun browser-entries ()
  (let ((root (nyxt-package-root)))
    (when root
      (loop for entry in (tree-entries root "")
            for name = (string-left-trim "/" (second entry))
            unless (equal name "") collect (list* (first entry) name (cddr entry))))))

(defun desktop-runtime-options ()
  (or *sbcl-runtime-options*
      (when (nyxt-package-root) '("--dynamic-space-size" "2048"))))

(defun desktop-disk-size ()
  (* (if (nyxt-package-root) 4096 1024) 1048576))

(defun root-entries ()
  (let ((files (append (when *include-browser* (browser-entries)) (release-entries) (desktop-entries)
                       (firmware-entries)
                       (ocicl-entries)
                       (contribs)
                       (certificates)
                       (zoneinfo)
                       (library-entries)
                       (object-entries)
                       (compiler-entries)
                       (source-entries)))
        (dirs (list "tmp" "Users" "Users/darterfly" "dev" "Volumes" "System" "System/Library" "System/Library/Kernels")))
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

(defun root-disk (&optional (path (build-path "root.img")) (size (* 512 1048576)) (entries (root-entries)))
  (darterfly/apfs:newfs path :size size :volume-name "darterfly HD" :entries entries
                         :container-uuid "F1C40000-0000-4000-8000-000000000001"
                         :volume-uuid "F1C40000-0000-4000-8000-000000000002"))

(defun same-content-p (path octets)
  (let ((attr (ignore-errors (darterfly/vfs:vfs-stat path))))
    (and attr (= (darterfly/vfs:vattr-size attr) (length octets))
         (let ((fd (darterfly/vfs:vfs-open path (list :access :rdonly) 0)))
           (unwind-protect (equalp (darterfly/vfs:vfs-read fd (length octets)) octets)
             (darterfly/vfs:vfs-close fd))))))

(defun update-root (path &optional (entries (root-entries)))
  (let ((darterfly/vfs:*root* nil) (darterfly/vfs:*mounts* nil))
    (darterfly/vfs:vfs-mount (darterfly/vfs:make-ram-node :vdir #o755) "/")
    (darterfly/vfs:vfs-mkdir "/root" #o755)
    (multiple-value-bind (read write) (darterfly/apfs:file-store path)
      (darterfly/apfs:mount-writable read write "/root"))
    (darterfly/apfs:with-batch
      (update-entries entries))
    path))

(defun update-entries (entries)
  (dolist (entry entries)
    (let ((at (format nil "/root/~a" (second entry))))
      (ecase (first entry)
        (:dir (unless (ignore-errors (darterfly/vfs:vfs-stat at)) (darterfly/vfs:vfs-mkdir at #o755)))
        (:file (destructuring-bind (octets &optional (mode #o644) time) (cddr entry)
                 (declare (ignore time))
                 (unless (same-content-p at octets)
                   (let ((fd (darterfly/vfs:vfs-open at (list :access :wronly :creat t :trunc t) (logand mode #o7777))))
                     (unwind-protect (darterfly/vfs:vfs-write fd octets)
                       (darterfly/vfs:vfs-close fd))))))))))

(defun esp (&key (boot-args "") root-image)
  (let ((root (build-path "esp/")))
    (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore)
    (flet ((put (from to)
             (let ((path (merge-pathnames to root)))
               (ensure-directories-exist path)
               (uiop:copy-file from path))))
      (let ((efi (boot-efi)))
        (put efi "EFI/BOOT/BOOTX64.EFI"))
      (put (kernel-file) "EFI/darterfly/gen-1/kernel")
      (put (darterfly-core) "EFI/darterfly/gen-1/darterfly.core")
      (put (ramdisk) "System/Library/RAMDisk/root.cpio")
      (when root-image (put root-image "System/Library/RAMDisk/root.img")))
    (with-open-file (s (merge-pathnames "EFI/darterfly/current" root) :direction :output)
      (write-line "gen-1" s))
    (with-open-file (s (merge-pathnames "EFI/darterfly/boot.conf" root) :direction :output :if-exists :supersede)
      (write-string (boot-conf boot-args root-image) s))
    root))

(defun esp-image (esp &optional (image (build-path "esp.img")) (size (* 256 1048576)))
  (let ((root (uiop:ensure-directory-pathname esp))
        (entries nil))
    (labels ((relative (p) (enough-namestring p root))
             (walk (dir)
               (dolist (sub (sort (uiop:subdirectories dir) #'string< :key #'namestring))
                 (push (list :dir (string-right-trim "/" (relative sub))) entries)
                 (walk sub))
               (dolist (f (sort (uiop:directory-files dir) #'string< :key #'namestring))
                 (push (list :file (relative f)
                             (with-open-file (s f :element-type '(unsigned-byte 8))
                               (let ((v (make-array (file-length s) :element-type '(unsigned-byte 8))))
                                 (read-sequence v s)
                                 v)))
                       entries))))
      (walk root))
    (darterfly/fat:newfs image :size size :label "EFI" :entries (nreverse entries))))

(defun nrepl-key ()
  (let ((file (build-path "nrepl.key")))
    (unless (probe-file file)
      (with-open-file (s file :direction :output)
        (let ((state (make-random-state t)))
          (format s "~{~(~8,'0x~)~}~%" (loop repeat 4 collect (random (ash 1 32) state))))))
    (with-open-file (s file) (read-line s))))

(defun boot-payload ()
  (flet ((file (name path) (list :file (concatenate 'string "usr/lib/darterfly/boot/" name) (octets path))))
    (list (list :dir "usr/lib/darterfly/boot")
          (file "boot.efi" (boot-efi)) (file "kernel" (kernel-file))
          (file "darterfly.core" (darterfly-core)) (file "root.cpio" (ramdisk)))))

(defun usb-image (&key (path (build-path "darterfly-usb.img")) (boot-args (format nil "rd=ram init nrepl-key=~a" (nrepl-key))))
  (let* ((*include-browser* t)
         (*sbcl-runtime-options* (desktop-runtime-options))
         (fat (esp-image (esp :boot-args boot-args
                             :root-image (root-disk (build-path "usb-root.img") (min (desktop-disk-size) (* 2048 1048576))
                                                    (append (root-entries) (boot-payload))))
                        (build-path "usb-esp.img") (+ (min (desktop-disk-size) (* 2048 1048576)) (* 512 1048576)))))
    (darterfly/gpt:write-disk path (list (list darterfly/gpt:+esp-type+ "F1C40000-0000-4000-8000-000000000011" "EFI" fat)))
    (delete-file fat)
    path))

(defun firmware (name)
  (format nil "~a/share/firmware/~a" (uiop:getenv "GUIX_ENVIRONMENT") name))

(defvar *input-devices* '("virtio-keyboard-pci" "virtio-tablet-pci"))
(defvar *network-device* "virtio-net-pci,netdev=net0,romfile=")
(defvar *extra-qemu* nil)
(defvar *reboot* nil)

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
         for nvme = (and (consp disk) (eq (car disk) :nvme))
         append (list "-drive" (format nil "if=none,id=disk~d,format=raw,file=~a" i (uiop:native-namestring (if nvme (second disk) disk)))
                      "-device" (if nvme
                                    (format nil "nvme,serial=nvme~d,drive=disk~d~@[,addr=~a~]" i i (getf (cddr disk) :addr))
                                    (format nil "virtio-blk-pci,drive=disk~d" i))))
   (list "-netdev" (format nil "user,id=net0~{,hostfwd=~(~a~)::~d-:~d~}" (loop for (proto host guest) in forwards append (list proto host guest))))
   (loop :for device :in *input-devices* :append (list "-device" device))
   (when *network-device* (list "-device" *network-device*))
   *extra-qemu*
   (list "-device" "isa-debug-exit,iobase=0xf4,iosize=0x04"
        "-monitor" (format nil "unix:~a,server=on,wait=off" (monitor-path))
        "-qmp" (format nil "unix:~a,server=on,wait=off" (qmp-path))
        "-display" "none" "-serial" "stdio")
   (unless *reboot* (list "-no-reboot"))))

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
               (dolist (file (sort (uiop:directory-files dir) #'string< :key #'namestring))
                 (unless (or (member (concatenate 'string relative (file-namestring file)) skip :test #'string=)
                             (not (funcall keep file)))
                   (push (list :file (format nil "~a/~a" at (file-namestring file)) (octets file)
                               (if (logtest #o111 (sb-posix:stat-mode (sb-posix:stat (uiop:native-namestring file)))) #o755 #o644)
                               (file-time file))
                         entries)))
               (dolist (sub (sort (uiop:subdirectories dir) #'string< :key #'namestring))
                 (let ((name (car (last (pathname-directory sub)))))
                   (unless (or (member (concatenate 'string relative name) skip :test #'string=)
                               (sb-posix:s-islnk (sb-posix:stat-mode (sb-posix:lstat (string-right-trim "/" (uiop:native-namestring sub))))))
                     (walk sub (format nil "~a/~a" at name) (concatenate 'string relative name "/")))))))
      (walk (uiop:ensure-directory-pathname from) (string-trim "/" to) ""))
    (nreverse entries)))

(defun copy-in (from to &key (disk (build-path "darterfly-hd.img")) (skip '(".git")))
  (when (in-use-p disk)
    (error "~a is in use by a running darterfly; quit that one first" (uiop:native-namestring disk)))
  (update-root disk (tree-entries from to :skip skip)))

(defun in-use-p (disk)
  (not (zerop (nth-value 2 (uiop:run-program (list "qemu-io" "-f" "raw" "-c" "quit" (uiop:native-namestring disk))
                                             :ignore-error-status t :output nil :error-output nil)))))

(defun desktop (&key (disk (build-path "darterfly-hd.img")))
  (when (and (probe-file disk) (in-use-p disk))
    (error "~a is in use by a running darterfly; quit that one first" (uiop:native-namestring disk)))
  (let* ((*include-browser* t)
         (*sbcl-runtime-options* (desktop-runtime-options))
         (*extra-qemu* (append (when (nyxt-package-root) '("-m" "8192")) *extra-qemu*))
         (root (if (probe-file disk) (update-root disk) (root-disk disk (desktop-disk-size))))
        (esp (build-path "desktop/esp/")))
    (uiop:delete-directory-tree esp :validate t :if-does-not-exist :ignore)
    (run "cp" "-a" (uiop:native-namestring (esp :boot-args (root-boot-args "init" t)))
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
