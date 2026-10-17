(defpackage #:darterfly/kernel
  (:use #:cl)
  (:export #:launch #:halt))
(in-package #:darterfly/kernel)

(defconstant +rb-power-off+ #x4321fedc)

(defun reboot (how)
  (sb-alien:alien-funcall (sb-alien:extern-alien "reboot" (function sb-alien:int sb-alien:int)) how))

(defun drain ()
  (finish-output)
  (sb-alien:alien-funcall (sb-alien:extern-alien "tcdrain" (function sb-alien:int sb-alien:int)) 1))

(defun halt ()
  (drain)
  (darterfly/vfs:vfs-sync)
  (reboot +rb-power-off+))

(defun launch ()
  (setf darterfly/bsd:*reboot* (lambda (how) (declare (ignore how)) (halt)))
  (dotimes (i 3)
    (darterfly/bsd:open "/dev/console" darterfly/bsd:+o-rdwr+))
  (let ((init (darterfly/bsd:fork (lambda () (darterfly/bsd:execve "/sbin/init" (list "/sbin/init") nil)))))
    (format t "~&load_init_program: /sbin/init pid ~d~%" init)
    (finish-output)
    init))
