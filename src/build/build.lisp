(defpackage #:finch/build
  (:use #:cl)
  (:export #:*sbcl-version* #:sbcl-config #:write-files #:runtime-tree #:libtcc-tree #:tree-files #:tree-differences
           #:digest #:digest-tree #:manifest #:write-manifest))
(in-package #:finch/build)

(defparameter *sbcl-version* "2.6.4.finch")

(defparameter *sbcl-features* ";;;; This is a machine-generated file.
;;;; Please do not edit it by hand.
;;;; See make-config.sh.
(lambda (features) (set-difference (union features (list :x86-64 :sb-thread
 :os-provides-clock-gettime :unix :linux :elf :gcc-tls :use-sys-mmap :largefile :sb-simd-pack :sb-simd-pack-256 :avx2 :immobile-space :little-endian :os-provides-dlopen :os-provides-dladdr :os-provides-blksize-t :os-provides-suseconds-t :os-provides-getprotoby-r :os-provides-poll :os-provides-close-range-wrapper :os-provides-posix-spawn :int3-breakpoints
:64-bit
:linkage-space
:gencgc
:use-cons-region
:relocatable-static-space
:soft-card-marks
:stack-grows-downward-not-upward
:c-stack-is-control-stack
:compare-and-swap-vops
:unwind-to-frame-and-call-vop
:fp-and-pc-standard-save
:alien-callbacks
:cycle-counter
:undefined-fun-restarts
:call-symbol
:executable-funinstances
:unbind-in-unwind
:no-continue-unwind)) (list)))
")

(defparameter *sbcl-build-config* "GNUMAKE=\"make\"; export GNUMAKE
SBCL_XC_HOST=\"sbcl --no-userinit --no-sysinit\"; export SBCL_XC_HOST
android=false; export android
SBCL_CONTRIB_BLOCKLIST=\"\"; export SBCL_CONTRIB_BLOCKLIST
")

(defun sbcl-config (build-id)
  (list (cons "local-target-features.lisp-expr" *sbcl-features*)
        (cons "version.lisp-expr" (format nil "~s~%" *sbcl-version*))
        (cons "output/build-id.inc" (format nil "~s~%" build-id))
        (cons "output/dynamic-space-size.txt" (string #\Newline))
        (cons "output/prefix.def" (format nil "SBCL_PREFIX='/usr/local'~%"))
        (cons "output/build-config" *sbcl-build-config*)))

(defun write-files (root files)
  (loop :for (relative . text) :in files
        :for path := (concatenate 'string root relative)
        :do (ensure-directories-exist path)
            (with-open-file (s path :direction :output :if-exists :supersede)
              (write-string text s))))

(defparameter *runtime-patches*
  '(("x86-64-assem.S" "	Lea	(%rdx,%rcx), %r9" "	lea	(%rdx,%rcx), %r9")
    ("x86-64-arch.c" "__asm__(\"xgetbv;\"" "__asm__(\".byte 0x0f, 0x01, 0xd0;\"")
    ("x86-64-assem.S" "#if defined(LISP_FEATURE_DARWIN) || defined(LISP_FEATURE_WIN32)
#define LOAD_PIC_VAR"
     "#if defined __finch__ || defined(LISP_FEATURE_DARWIN) || defined(LISP_FEATURE_WIN32)
#define LOAD_PIC_VAR")
    ("x86-64-arch.c" "#if defined __linux__
    /* KLUDGE" "#if defined __finch__
#   define CONTEXT_FLAGS(c) c->rflags
#elif defined __linux__
    /* KLUDGE")
    ("x86-64-assem.S" "#if defined __linux__  || defined LISP_FEATURE_HAIKU"
     "#if defined __finch__ || defined __linux__  || defined LISP_FEATURE_HAIKU")
    ("run-program.c" "    pid = fork();
    if (pid) {"
     "#if defined __finch__
    extern int __libsa_spawn(char *, char **, int, int, int, int, char **, char *);
    (void)sset; (void)failure_code; (void)pty_name; (void)dont_close;
    return __libsa_spawn(program, argv, sin, sout, serr, search, envp, pwd);
#endif
    pid = fork();
    if (pid) {")
    ("x86-64-arch.c" "        ALIEN_LINKAGE_SPACE_START = (uword_t)addr - ALIEN_LINKAGE_SPACE_SIZE;
    }
    return addr;"
     "        ALIEN_LINKAGE_SPACE_START = (uword_t)addr - ALIEN_LINKAGE_SPACE_SIZE;
    }
#if defined __finch__
    if (space_id == STATIC_CORE_SPACE_ID && lisp_code_in_elf()) {
        os_vm_address_t near = os_alloc_gc_space(ALIEN_LINKAGE_TABLE_CORE_SPACE_ID, NOT_MOVABLE,
                                                 (os_vm_address_t)(0x100000000000UL - ALIEN_LINKAGE_SPACE_SIZE),
                                                 ALIEN_LINKAGE_SPACE_SIZE);
        if (near) ALIEN_LINKAGE_SPACE_START = (uword_t)near;
    }
#endif
    return addr;")))

(defun copy-into (from to)
  (ensure-directories-exist to)
  (uiop:copy-file from to))

(defun runtime-tree (sbcl-root finch-sbcl out-root &key (genesis (concatenate 'string sbcl-root "src/runtime/genesis/")))
  (let ((from (concatenate 'string sbcl-root "src/runtime/"))
        (to (concatenate 'string out-root "src/runtime/")))
    (uiop:delete-directory-tree (pathname out-root) :validate t :if-does-not-exist :ignore)
    (dolist (f (uiop:directory-files from))
      (unless (member (pathname-type f) '("o" "d") :test #'equal)
        (copy-into f (merge-pathnames (file-namestring f) to))))
    (loop :for (target source) :in '(("Config" "Config.x86-64-linux") ("target-arch.h" "x86-64-arch.h")
                                     ("target-lispregs.h" "x86-64-lispregs.h"))
          :do (uiop:copy-file (merge-pathnames source to) (merge-pathnames target to)))
    (dolist (f (uiop:directory-files genesis))
      (copy-into f (merge-pathnames (concatenate 'string "genesis/" (file-namestring f)) to)))
    (dolist (f (uiop:directory-files (concatenate 'string sbcl-root "tlsf-bsd/tlsf/")))
      (copy-into f (concatenate 'string out-root "tlsf-bsd/tlsf/" (file-namestring f))))
    (copy-into (concatenate 'string sbcl-root "tlsf-bsd/tlsf/tlsf.c") (merge-pathnames "tlsf.c" to))
    (copy-into (concatenate 'string sbcl-root "output/build-id.inc") (concatenate 'string out-root "output/build-id.inc"))
    (dolist (f (uiop:directory-files finch-sbcl))
      (copy-into f (merge-pathnames (file-namestring f) to)))
    (uiop:copy-file (merge-pathnames "finch-os.h" to) (merge-pathnames "target-os.h" to))
    (uiop:copy-file (merge-pathnames "x86-64-finch-os.h" to) (merge-pathnames "target-arch-os.h" to))
    (loop :for (file old new) :in *runtime-patches*
          :for path := (merge-pathnames file to)
          :for text := (uiop:read-file-string path)
          :for at := (search old text)
          :do (unless at (error "runtime patch for ~a no longer applies" file))
              (with-open-file (o path :direction :output :if-exists :supersede)
                (write-string (concatenate 'string (subseq text 0 at) new (subseq text (+ at (length old)))) o)))
    to))

(defparameter *libtcc-config*
  "#define TCC_VERSION \"0.9.28rc\"
#define CC_NAME CC_tcc
#define GCC_MAJOR 0
#define GCC_MINOR 928
#define TCC_TARGET_X86_64 1
#define CONFIG_TCC_SYSINCLUDEPATHS \"{B}/include\"
#define CONFIG_TCC_LIBPATHS \"{B}\"
#define CONFIG_TCC_CRTPREFIX \"{B}\"
#define CONFIG_TCC_ELFINTERP \"-\"
#define CONFIG_TCCDIR \"/usr/lib/tcc\"
#define CONFIG_TCC_PREDEFS 1
")

(defun libtcc-tree (tcc-root out-root tccdefs)
  (uiop:delete-directory-tree (pathname out-root) :validate t :if-does-not-exist :ignore)
  (ensure-directories-exist out-root)
  (dolist (file (append (directory (concatenate 'string tcc-root "*.c"))
                        (directory (concatenate 'string tcc-root "*.h"))
                        (directory (concatenate 'string tcc-root "*.def"))
                        (list tccdefs)))
    (uiop:copy-file file (concatenate 'string out-root (file-namestring file))))
  (with-open-file (o (concatenate 'string out-root "config.h") :direction :output :if-exists :supersede)
    (write-string *libtcc-config* o))
  out-root)

(defun tree-files (root)
  (let ((root (uiop:ensure-directory-pathname root)))
    (labels ((walk (dir)
               (append (uiop:directory-files dir)
                       (mapcan #'walk (uiop:subdirectories dir)))))
      (sort (mapcar (lambda (f) (enough-namestring f root)) (walk root)) #'string<))))

(defun file-octets (path)
  (with-open-file (s path :element-type '(unsigned-byte 8))
    (let ((v (make-array (file-length s) :element-type '(unsigned-byte 8))))
      (read-sequence v s)
      v)))

(defun tree-differences (a b)
  (let ((in-a (tree-files a)) (in-b (tree-files b)))
    (append (mapcar (lambda (f) (list :only-in-a f)) (set-difference in-a in-b :test #'string=))
            (mapcar (lambda (f) (list :only-in-b f)) (set-difference in-b in-a :test #'string=))
            (loop :for f :in (intersection in-a in-b :test #'string=)
                  :unless (equalp (file-octets (merge-pathnames f (uiop:ensure-directory-pathname a)))
                                  (file-octets (merge-pathnames f (uiop:ensure-directory-pathname b))))
                    :collect (list :differs f)))))

(defun digest (path)
  (string-downcase (format nil "~{~2,'0x~}" (coerce (sb-md5:md5sum-file path) 'list))))

(defun digest-tree (root &key (keep (constantly t)))
  (loop :for relative :in (tree-files root)
        :for path := (merge-pathnames relative (uiop:ensure-directory-pathname root))
        :when (funcall keep path)
          :collect (list relative (digest path) (with-open-file (s path :element-type '(unsigned-byte 8)) (file-length s)))))

(defun manifest (&key sources outputs parent build-id)
  (list :build-id build-id
        :parent parent
        :sources (loop :for (name root) :in sources :collect (list name root (digest-tree root)))
        :outputs (loop :for (name path) :in outputs :collect (list name path (digest path)))))

(defun write-manifest (path manifest)
  (ensure-directories-exist path)
  (with-open-file (s path :direction :output :if-exists :supersede)
    (with-standard-io-syntax
      (let ((*print-readably* nil) (*print-right-margin* 120))
        (pprint manifest s))))
  path)
