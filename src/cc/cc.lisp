(defpackage #:darterfly/cc
  (:use #:cl)
  (:export #:arguments #:compile-c #:run-c #:units #:compile-units
           #:compile-native-c #:link-native-program #:build-native-tcc))
(in-package #:darterfly/cc)

(defun arguments (source &key includes defines (compat t) tcc-dir libsa-dir)
  (let ((asm (member (pathname-type source) '("S" "s") :test #'string=)))
    (append (list (format nil "-B~a" tcc-dir) "-nostdinc" "-D__darterfly__"
                  "-U__linux__" "-U__linux" "-U__unix__" "-U__unix")
            (cond (asm (list "-fno-dollars-in-identifiers"))
                  (compat (list "-include" (format nil "~ainclude/tinycc.h" libsa-dir))))
            (list "-isystem" (format nil "~ainclude" libsa-dir) "-isystem" (format nil "~ainclude" tcc-dir))
            (mapcar (lambda (d) (format nil "-D~a" d)) defines)
            (loop :for i :in includes :append (list "-I" i)))))

(defmacro tcc (name result &rest args)
  `(sb-alien:alien-funcall
    (sb-alien:extern-alien ,name (function ,result ,@(mapcar #'first args)))
    ,@(mapcar #'second args)))

(defun compile-c (source object &key includes defines (compat t) directory
                                     (tcc-dir "/usr/lib/tcc/") (libsa-dir "/usr/src/darterfly/src/libsa/"))
  (let ((options (format nil "~{~a~^ ~}" (arguments source :includes includes :defines defines :compat compat
                                                             :tcc-dir tcc-dir :libsa-dir libsa-dir)))
        (state (tcc "tcc_new" sb-sys:system-area-pointer))
        (was (when directory (namestring (uiop:getcwd)))))
    (unwind-protect
         (sb-int:with-float-traps-masked (:overflow :invalid :divide-by-zero :inexact :underflow)
           (when directory (uiop:chdir directory))
           (uiop:delete-file-if-exists object)
           (or (and (zerop (tcc "tcc_set_options" sb-alien:int (sb-sys:system-area-pointer state) (sb-alien:c-string options)))
                (zerop (tcc "tcc_set_output_type" sb-alien:int (sb-sys:system-area-pointer state) (sb-alien:int 3)))
                (zerop (tcc "tcc_add_file" sb-alien:int (sb-sys:system-area-pointer state) (sb-alien:c-string source)))
                (zerop (tcc "tcc_output_file" sb-alien:int (sb-sys:system-area-pointer state) (sb-alien:c-string object))))
               (progn (uiop:delete-file-if-exists object) nil)))
      (when was (uiop:chdir was))
      (tcc "tcc_delete" sb-alien:void (sb-sys:system-area-pointer state)))))

(defparameter *libsa-sources* '())

(defparameter *runtime-sources*
  '("alloc.c" "arena.c" "backtrace.c" "breakpoint.c" "coalesce.c" "coreparse.c" "dynbind.c" "funcall.c"
    "gc-common.c" "globals.c" "hopscotch.c" "interr.c" "interrupt.c" "largefile.c" "main.c" "math.c"
    "monitor.c" "murmur_hash.c" "os-common.c" "parse.c" "perfecthash.c" "print.c" "time.c" "regnames.c"
    "runtime.c" "safepoint.c" "save.c" "sc-offset.c" "search.c" "stringspace.c" "thread.c"
    "stop-the-world.c" "validate.c" "var-io.c" "vars.c" "wrap.c" "run-program.c" "sprof.c"
    "x86-64-arch.c" "fullcgc.c" "gencgc.c" "traceroot.c" "immobile-space.c" "tlsf.c"
    "darterfly-os.c" "x86-64-darterfly-os.c" "x86-64-assem.S"))

(defparameter *libtcc1-sources* '("libtcc1.c" "va_list.c" "stdatomic.c" "atomic.S" "builtin.c" "alloca.S"))

(defun units (&key (libtcc1 t))
  (flet ((unit (group dir file &rest options)
           (list* :name (format nil "~a/~a.o" group (pathname-name file)) :source (concatenate 'string dir file) options)))
    (append (mapcar (lambda (f) (unit "libsa" "src/libsa/" f :includes '("src/libsa/"))) *libsa-sources*)
            (mapcar (lambda (f) (unit "runtime" "build/runtime/src/runtime/" f
                                      :includes '("build/runtime/src/runtime/" "build/runtime/tlsf-bsd/tlsf/")))
                    *runtime-sources*)
            (list (unit "libtcc" "build/tcc/darterfly-src/" "libtcc.c" :includes '("build/tcc/darterfly-src/" "src/libsa/")
                        :defines '("ONE_SOURCE=1" "TCC_TARGET_X86_64=1" "CONFIG_TCC_BACKTRACE=0")))
            (when libtcc1
              (mapcar (lambda (f) (unit "libtcc1" "build/tcc/stage2/lib/" f :compat nil)) *libtcc1-sources*)))))

(defun compile-units (out &key (directory "/usr/src/darterfly/") (units (units)))
  (let ((failed (loop :for unit :in units
                      :for object := (concatenate 'string out (getf unit :name))
                      :do (ensure-directories-exist object)
                      :unless (compile-c (getf unit :source) object :directory directory
                                         :includes (getf unit :includes) :defines (getf unit :defines)
                                         :compat (getf unit :compat t))
                        :collect (getf unit :name))))
    (if failed
        (uiop:delete-file-if-exists (concatenate 'string out "objects"))
        (with-open-file (s (concatenate 'string out "objects") :direction :output :if-exists :supersede)
          (format s "~{~a~%~}" (mapcar (lambda (unit) (getf unit :name)) units))))
    failed))

(defun run-c (source &key args output includes defines (compat t) directory
                          (tcc-dir "/usr/lib/tcc/") (libsa-dir "/usr/src/darterfly/src/libsa/"))
  (let ((options (format nil "~{~a~^ ~}" (arguments source :includes includes :defines defines :compat compat
                                                                       :tcc-dir tcc-dir :libsa-dir libsa-dir)))
        (state (tcc "tcc_new" sb-sys:system-area-pointer))
        (was (when directory (namestring (uiop:getcwd)))))
    (unwind-protect
         (sb-int:with-float-traps-masked (:overflow :invalid :divide-by-zero :inexact :underflow)
           (when directory (uiop:chdir directory))
           (when (and (zerop (tcc "tcc_set_options" sb-alien:int (sb-sys:system-area-pointer state) (sb-alien:c-string options)))
                      (zerop (tcc "tcc_set_output_type" sb-alien:int (sb-sys:system-area-pointer state) (sb-alien:int 1)))
                      (zerop (tcc "tcc_add_file" sb-alien:int (sb-sys:system-area-pointer state) (sb-alien:c-string source)))
                      (<= 0 (tcc "tcc_relocate" sb-alien:int (sb-sys:system-area-pointer state))))
             (let ((main (tcc "tcc_get_symbol" sb-sys:system-area-pointer (sb-sys:system-area-pointer state) (sb-alien:c-string "main"))))
               (unless (zerop (sb-sys:sap-int main))
                 (let* ((argv (cons source args))
                        (vector (sb-alien:make-alien sb-alien:c-string (1+ (length argv)))))
                   (loop :for arg :in argv :for i :from 0 :do (setf (sb-alien:deref vector i) arg))
                   (setf (sb-alien:deref vector (length argv)) nil)
                   (when output (tcc "__libsa_redirect_stdout" sb-alien:int (sb-alien:c-string output)))
                   (unwind-protect
                        (sb-alien:alien-funcall
                         (sb-alien:sap-alien main (function sb-alien:int sb-alien:int (* sb-alien:c-string)))
                         (length argv) vector)
                     (when output (tcc "__libsa_redirect_stdout" sb-alien:int (sb-alien:c-string nil)))))))))
      (when was (uiop:chdir was))
      (tcc "tcc_delete" sb-alien:void (sb-sys:system-area-pointer state)))))
