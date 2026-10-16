(defpackage #:finch/kern
  (:use #:cl #:finch/low)
  (:export #:kern-object))
(in-package #:finch/kern)

(defconstant +page-size+ 4096)
(defconstant +physmap-base+ #xFFFF800000000000)

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
