(defpackage #:finch/kernel
  (:use #:cl)
  (:export #:start #:boot-args #:version #:halt))
(in-package #:finch/kernel)

(defparameter *version* "0.1")

(defun version ()
  (format nil "finch Kernel Version ~a: ~a; SBCL ~a"
          *version* (build-date) (lisp-implementation-version)))

(defvar *build-date* nil)

(defun build-date ()
  (or *build-date* "unreleased"))

(defun os-error (what)
  (error "~a: ~a" what (sb-int:strerror)))

(defun mount (source target type &optional (flags 0))
  (ensure-directories-exist (format nil "~a/" target))
  (unless (zerop (sb-alien:alien-funcall
                  (sb-alien:extern-alien "mount" (function sb-alien:int sb-alien:c-string sb-alien:c-string
                                                           sb-alien:c-string sb-alien:unsigned-long
                                                           sb-alien:system-area-pointer))
                  source target type flags (sb-sys:int-sap 0)))
    (os-error (format nil "mount ~a on ~a" type target))))

(defconstant +rb-power-off+ #x4321fedc)
(defconstant +rb-autoboot+ #x1234567)

(defun reboot (how)
  (sb-alien:alien-funcall (sb-alien:extern-alien "sync" (function sb-alien:void)))
  (sb-alien:alien-funcall (sb-alien:extern-alien "reboot" (function sb-alien:int sb-alien:int)) how))

(defun drain ()
  (finish-output)
  (sb-alien:alien-funcall (sb-alien:extern-alien "tcdrain" (function sb-alien:int sb-alien:int)) 1))

(defun halt ()
  (drain)
  (reboot +rb-power-off+))

(defun boot-args ()
  (with-open-file (s "/proc/cmdline")
    (remove "" (uiop:split-string (string-trim '(#\Newline #\Space) (read-line s)) :separator " ")
            :test #'string=)))

(defun boot-arg-p (name)
  (member name (boot-args) :test #'string=))

(defun kernel-bootstrap ()
  (format t "~a~%" (version))
  (format t "kernel_bootstrap: kernel task ~a~%" finch/mach:*task*))

(defun bsd-init ()
  (mount "proc" "/proc" "proc")
  (mount "sysfs" "/sys" "sysfs")
  (mount "devtmpfs" "/dev" "devtmpfs")
  (mount "tmpfs" "/tmp" "tmpfs")
  (format t "bsd_init: boot-args ~{~a~^ ~}~%" (boot-args)))

(defun load-init-program ()
  (cond ((boot-arg-p "halt")
         (format t "load_init_program: halt~%")
         (halt))
        (t
         (format t "load_init_program: console~%")
         (finish-output)
         (sb-impl::toplevel-repl nil))))

(defun start ()
  (handler-case
      (progn
        (kernel-bootstrap)
        (bsd-init)
        (load-init-program))
    (error (e)
      (format t "panic: ~a~%" e)
      (halt)))
  (halt))
