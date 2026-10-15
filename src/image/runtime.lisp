(in-package #:finch/image)

(defun sbcl-tree () (asdf:system-relative-pathname :finch "build/sbcl-mt/"))

(defparameter *sbcl-version* "2.6.4.finch")

(defun build-sbcl ()
  (let ((source (format nil "~a/share/sbcl-source/" (uiop:getenv "GUIX_ENVIRONMENT")))
        (tree (sbcl-tree)))
    (uiop:delete-directory-tree tree :validate t :if-does-not-exist :ignore)
    (run "cp" "-r" "--preserve=timestamps" source (uiop:native-namestring (string-right-trim "/" (uiop:native-namestring tree))))
    (run "chmod" "-R" "u+w" (uiop:native-namestring tree))
    (with-open-file (s (merge-pathnames "version.lisp-expr" tree) :direction :output :if-exists :supersede)
      (prin1 *sbcl-version* s)
      (terpri s))
    (with-open-file (log (build-path "sbcl-mt-build.log") :direction :output :if-exists :supersede)
      (uiop:run-program (list "env" "CC=gcc" "sh" "make.sh" "--xc-host=sbcl --no-userinit --no-sysinit")
                        :directory tree :output log :error-output log))
    (unless (probe-file (merge-pathnames "output/sbcl.core" tree))
      (error "sbcl did not build; see ~a" (uiop:native-namestring (build-path "sbcl-mt-build.log"))))
    tree))

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

(defun runtime-dir () (build-path "runtime/src/runtime/"))

(defun copy-into (from to)
  (ensure-directories-exist to)
  (uiop:copy-file from to))

(defun runtime-tree ()
  (let* ((from (merge-pathnames "src/runtime/" (sbcl-tree)))
         (root (build-path "runtime/"))
         (to (runtime-dir)))
    (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore)
    (dolist (f (uiop:directory-files from))
      (unless (member (pathname-type f) '("o" "d") :test #'equal)
        (copy-into f (merge-pathnames (file-namestring f) to))))
    (dolist (f (uiop:directory-files (merge-pathnames "genesis/" from)))
      (copy-into f (merge-pathnames (concatenate 'string "genesis/" (file-namestring f)) to)))
    (dolist (f (uiop:directory-files (merge-pathnames "tlsf-bsd/tlsf/" (sbcl-tree))))
      (copy-into f (merge-pathnames (concatenate 'string "tlsf-bsd/tlsf/" (file-namestring f)) root)))
    (copy-into (merge-pathnames "tlsf-bsd/tlsf/tlsf.c" (sbcl-tree)) (merge-pathnames "tlsf.c" to))
    (copy-into (merge-pathnames "output/build-id.inc" (sbcl-tree)) (merge-pathnames "output/build-id.inc" root))
    (dolist (f (uiop:directory-files (asdf:system-relative-pathname :finch "src/sbcl/")))
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

(defun runtime-flags ()
  (append (list "-target" "x86_64-unknown-none-elf" "-ffreestanding" "-fPIE" "-mno-red-zone"
                "-fno-stack-protector" "-fno-omit-frame-pointer" "-O2" "-g0"
                "-Wno-everything" "-Werror=implicit-function-declaration" "-Werror=implicit-int" "-D__finch__")
          (list "-isystem" (source "src/libsa/include"))
          (freestanding)))

