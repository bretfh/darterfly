(in-package #:finch/image)

(defparameter *runtime-sources*
  '("alloc.c" "arena.c" "backtrace.c" "breakpoint.c" "coalesce.c" "coreparse.c" "dynbind.c" "funcall.c"
    "gc-common.c" "globals.c" "hopscotch.c" "interr.c" "interrupt.c" "largefile.c" "main.c" "math.c"
    "monitor.c" "murmur_hash.c" "os-common.c" "parse.c" "perfecthash.c" "print.c" "time.c" "regnames.c"
    "runtime.c" "safepoint.c" "save.c" "sc-offset.c" "search.c" "stringspace.c" "thread.c"
    "stop-the-world.c" "validate.c" "var-io.c" "vars.c" "wrap.c" "run-program.c" "sprof.c"
    "x86-64-arch.c" "fullcgc.c" "gencgc.c" "traceroot.c" "immobile-space.c" "tlsf.c"
    "finch-os.c" "x86-64-finch-os.c" "x86-64-assem.S"))

(defun sbcl-tree () (asdf:system-relative-pathname :finch "build/sbcl/"))

(defparameter *runtime-patches*
  '(("x86-64-arch.c" "#if defined __linux__
    /* KLUDGE" "#if defined __finch__
#   define CONTEXT_FLAGS(c) c->rflags
#elif defined __linux__
    /* KLUDGE")
    ("x86-64-assem.S" "#if defined __linux__  || defined LISP_FEATURE_HAIKU"
     "#if defined __finch__ || defined __linux__  || defined LISP_FEATURE_HAIKU")))

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

(defun compile-runtime (&key (sources *runtime-sources*))
  (let ((tree (runtime-tree))
        (failures '()))
    (dolist (name sources)
      (let ((object (merge-pathnames (format nil "~a.o" (pathname-name name)) tree)))
        (multiple-value-bind (out err code)
            (uiop:run-program (append (list "clang") (runtime-flags)
                                      (list "-I" (uiop:native-namestring tree)
                                            "-I" (uiop:native-namestring (build-path "runtime/tlsf-bsd/tlsf/"))
                                            "-c" (uiop:native-namestring (merge-pathnames name tree))
                                            "-o" (uiop:native-namestring object)))
                              :output :string :error-output :output :ignore-error-status t)
          (declare (ignore err))
          (unless (zerop code) (push (cons name out) failures)))))
    (nreverse failures)))
