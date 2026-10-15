(in-package #:finch/image)

(defun tcc-source () (format nil "~a/share/tinycc-source/" (uiop:getenv "GUIX_ENVIRONMENT")))

(defun tcc-stage (n) (build-path (format nil "tcc/stage~d/" n)))

(defun tcc-of (n)
  (let ((dir (uiop:native-namestring (tcc-stage n))))
    (format nil "~atcc -B~a" dir dir)))

(defun build-tcc-stage (n cc)
  (let ((tree (tcc-stage n)))
    (uiop:delete-directory-tree tree :validate t :if-does-not-exist :ignore)
    (ensure-directories-exist tree)
    (run "cp" "-r" (concatenate 'string (tcc-source) ".") (uiop:native-namestring tree))
    (run "chmod" "-R" "u+w" (uiop:native-namestring tree))
    (let ((log (open (build-path (format nil "tcc/stage~d.log" n)) :direction :output :if-exists :supersede)))
     (unwind-protect
      (dolist (step (list (let ((env (uiop:getenv "GUIX_ENVIRONMENT")))
                            (list "sh" "configure" (format nil "--cc=~a" cc)
                                  (format nil "--crtprefix=~a/lib" env) (format nil "--libpaths={B}:~a/lib" env)
                                  (format nil "--sysincludepaths={B}/include:~a/include" env)
                                  (format nil "--elfinterp=~a/lib/ld-linux-x86-64.so.2" env)))
                          (list "make" "tcc" "libtcc1.a")))
        (multiple-value-bind (out err code)
            (uiop:run-program step :directory tree :output log :error-output log :ignore-error-status t)
          (declare (ignore out err))
          (unless (zerop code)
            (error "tcc stage ~d: ~{~a~^ ~} failed; see build/tcc/stage~d.log" n step n))))
       (close log)))
    (merge-pathnames "tcc" tree)))

(defun build-tcc ()
  (build-tcc-stage 1 "gcc")
  (build-tcc-stage 2 (tcc-of 1))
  (build-tcc-stage 3 (tcc-of 2))
  (let ((same (string= "" (run "sh" "-c" (format nil "cmp ~atcc ~atcc && echo"
                                                 (uiop:native-namestring (tcc-stage 2))
                                                 (uiop:native-namestring (tcc-stage 3)))))))
    (declare (ignore same))
    (tcc-stage 2)))

(defvar *c-compiler* :clang)

(defun tcc ()
  (let ((tcc (merge-pathnames "tcc" (tcc-stage 2))))
    (unless (probe-file tcc) (build-tcc))
    (uiop:native-namestring tcc)))

(defun tcc-flags (source &optional (compat t))
  (let ((stage (uiop:native-namestring (tcc-stage 2)))
        (asm (member (pathname-type source) '("S" "s") :test #'string=)))
    (append (list (format nil "-B~a" stage) "-nostdinc" "-D__finch__"
                  "-U__linux__" "-U__linux" "-U__unix__" "-U__unix")
            (cond (asm (list "-fno-dollars-in-identifiers"))
                  (compat (list "-include" (source "src/libsa/include/tinycc.h"))))
            (list "-isystem" (source "src/libsa/include") "-isystem" (format nil "~ainclude" stage)))))

(defvar *clang-files* nil)

(defun source-key (source)
  (let ((path (uiop:native-namestring source)))
    (concatenate 'string (if (search "/libsa/" path) "libsa/" "runtime/") (file-namestring path))))

(defun c-compile (source object &key includes clang-flags (compat t))
  (ensure-directories-exist object)
  (let ((*c-compiler* (if (member (source-key source) *clang-files* :test #'string=) :clang *c-compiler*))
        (source (uiop:native-namestring source))
        (object (uiop:native-namestring object))
        (includes (loop :for i :in includes :append (list "-I" (uiop:native-namestring i)))))
    (ecase *c-compiler*
      (:clang (append (list "clang") clang-flags includes (list "-c" source "-o" object)))
      (:tcc (append (list (tcc)) (tcc-flags source compat) includes (list "-c" source "-o" object))))))

(defun object-dir (name)
  (if (eq *c-compiler* :clang) name (format nil "~a-tcc" name)))

(defun object-path (dir source)
  (build-path (format nil "~a/~a.o" (object-dir dir) (pathname-name source))))

(defparameter *libtcc1-sources* '("libtcc1.c" "va_list.c" "stdatomic.c" "atomic.S" "builtin.c" "alloca.S"))

(defun libtcc1-object (source)
  (build-path (format nil "tcc/finch-lib/~a.o" (pathname-name source))))

(defun libtcc1-objects ()
  (when (eq *c-compiler* :tcc)
    (loop :for name :in *libtcc1-sources*
          :for object := (libtcc1-object name)
          :do (apply #'run (c-compile (merge-pathnames (concatenate 'string "lib/" name) (tcc-stage 2)) object :compat nil))
          :collect (uiop:native-namestring object))))
