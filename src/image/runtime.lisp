(in-package #:darterfly/image)

(defun sbcl-tree () (build-path "sbcl-mt/"))

(defun build-sbcl ()
  (let ((source (format nil "~a/share/sbcl-source/" (uiop:getenv "GUIX_ENVIRONMENT")))
        (tree (sbcl-tree)))
    (uiop:delete-directory-tree tree :validate t :if-does-not-exist :ignore)
    (run "cp" "-r" "--preserve=timestamps" source (uiop:native-namestring (string-right-trim "/" (uiop:native-namestring tree))))
    (run "chmod" "-R" "u+w" (uiop:native-namestring tree))
    (with-open-file (s (merge-pathnames "version.lisp-expr" tree) :direction :output :if-exists :supersede)
      (prin1 darterfly/build:*sbcl-version* s)
      (terpri s))
    ;; Preserve diagnostics on failure; WITH-OPEN-FILE abort can delete this log.
    (let ((log (open (build-path "sbcl-mt-build.log") :direction :output :if-exists :supersede)))
      (unwind-protect
           (uiop:run-program (list "env" "CC=gcc" "sh" "make.sh" "--xc-host=sbcl --no-userinit --no-sysinit")
                             :directory tree :output log :error-output log)
        (close log)))
    (unless (probe-file (merge-pathnames "output/sbcl.core" tree))
      (error "sbcl did not build; see ~a" (uiop:native-namestring (build-path "sbcl-mt-build.log"))))
    tree))

(defun runtime-dir () (build-path "runtime/src/runtime/"))

(defun runtime-tree ()
  (darterfly/build:runtime-tree (namestring (sbcl-tree)) (source "src/sbcl/") (namestring (build-path "runtime/"))))

(defun runtime-flags ()
  (append (list "-target" "x86_64-unknown-none-elf" "-ffreestanding" "-fPIE" "-mno-red-zone"
                "-fno-stack-protector" "-fno-omit-frame-pointer" "-O2" "-g0"
                "-Wno-everything" "-Werror=implicit-function-declaration" "-Werror=implicit-int" "-D__darterfly__")
          (list "-isystem" (source "src/libsa/include"))
          (freestanding)))

