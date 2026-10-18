(in-package #:darterfly/libsa)

(define-low setlocale (c l) "C")

(define-low dirname (p)
  (let ((s (strrchr p 47)))
    (cond ((= s 0) ".")
          ((= s p) "/")
          (t (setf (mem :u8 s) 0) p))))

(define-low basename (p)
  (let ((s (strrchr p 47)))
    (if (= s 0) p (+ s 1))))

(define-low prctl (o) 0)

(define-low _os_cpu_number () (rdtscp))
