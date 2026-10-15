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

(defvar *clang-files* nil)

(defun source-key (source)
  (let ((path (uiop:native-namestring source)))
    (concatenate 'string (if (search "/libsa/" path) "libsa/" "runtime/") (file-namestring path))))

(defun repo-relative (path)
  (let ((path (uiop:native-namestring path)) (root (source "")))
    (if (uiop:string-prefix-p root path) (subseq path (length root)) path)))

(defun c-compile (source object &key includes clang-flags (compat t) defines)
  (ensure-directories-exist object)
  (let ((*c-compiler* (if (member (source-key source) *clang-files* :test #'string=) :clang *c-compiler*))
        (source (repo-relative source))
        (object (uiop:native-namestring object))
        (includes (mapcar #'uiop:native-namestring includes)))
    (ecase *c-compiler*
      (:clang (append (list "clang") clang-flags (mapcar (lambda (d) (format nil "-D~a" d)) defines)
                      (loop :for i :in includes :append (list "-I" i)) (list "-c" source "-o" object)))
      (:tcc (append (list (tcc))
                    (finch/cc:arguments source :includes includes :defines defines :compat compat
                                               :tcc-dir (uiop:native-namestring (tcc-stage 2)) :libsa-dir (source "src/libsa/"))
                    (list "-c" source "-o" object))))))

(defun object-dir (name)
  (if (eq *c-compiler* :clang) name (format nil "~a-tcc" name)))


(defparameter *libtcc-patches*
  '(("tcc.h" "    && defined __APPLE__ == defined TCC_TARGET_MACHO
" "    && defined __APPLE__ == defined TCC_TARGET_MACHO && !defined __finch__
")))

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

(defun libtcc-tree ()
  (let ((tree (build-path "tcc/finch-src/")))
    (unless (probe-file (merge-pathnames "config.h" tree))
      (tcc)
      (ensure-directories-exist tree)
      (dolist (file (append (directory (concatenate 'string (tcc-source) "*.c"))
                            (directory (concatenate 'string (tcc-source) "*.h"))
                            (directory (concatenate 'string (tcc-source) "*.def"))
                            (list (merge-pathnames "tccdefs_.h" (tcc-stage 2)))))
        (uiop:copy-file file (merge-pathnames (file-namestring file) tree)))
      (loop :for (file old new) :in *libtcc-patches*
            :for path := (merge-pathnames file tree)
            :for text := (uiop:read-file-string path)
            :for at := (search old text)
            :do (unless at (error "libtcc patch for ~a no longer applies" file))
                (with-open-file (o path :direction :output :if-exists :supersede)
                  (write-string (concatenate 'string (subseq text 0 at) new (subseq text (+ at (length old)))) o)))
      (with-open-file (o (merge-pathnames "config.h" tree) :direction :output :if-exists :supersede)
        (write-string *libtcc-config* o)))
    tree))
