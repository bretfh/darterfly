(defpackage #:finch/osfmk
  (:use #:cl #:finch/low)
  (:export #:osfmk-object))
(in-package #:finch/osfmk)

(defconstant +ia32-cr-pat+ #x277)
(defconstant +pat-write-combined+ 1)

(define-low pat-init ()
  (let ((pat (rdmsr +ia32-cr-pat+)))
    (when (= (logand pat (ash 7 48)) (ash +pat-write-combined+ 48))
      (result 0))
    (setf pat (logior (logand pat (lognot (ash 7 48))) (ash +pat-write-combined+ 48)))
    (wbinvd)
    (wrmsr +ia32-cr-pat+ pat)
    (wbinvd)))
