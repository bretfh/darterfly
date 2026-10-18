(defpackage #:darterfly/libsa
  (:use #:cl #:darterfly/low)
  (:shadow #:basename)
  (:export #:libsa-object))
(in-package #:darterfly/libsa)

(define-low __syscall (n a b c d e f)
  (let ((r (trap-errno #x80 n a b c d e f)))
    (if (signed< r 0)
        (progn (setf (mem :u32 (__errno_location)) (- 0 r)) (- 0 1))
        r)))

(define-low __machdep5 (n a b c d e)
  (trap #x82 n a b c d e))

(define-low __machdep (n a b)
  (trap #x82 n a b 0 0 0))

(defun libsa-object () (package-object "DARTERFLY/LIBSA" :extra (list "va_next") :routines (jump-routines)))
