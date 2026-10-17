(in-package #:darterfly/kern)

(defconstant +ia32-pm-enable+ #x770)
(defconstant +ia32-hwp-capabilities+ #x771)
(defconstant +ia32-hwp-request+ #x774)
(defconstant +hwp-balanced+ #x80)

(define-global idle-hint :u64)

(define-low deepest-mwait ()
  (let ((states (the :u32 (cpuid 5 :edx))) (n 7))
    (while (and n (= (logand (shr states (* 4 n)) 15) 0))
      (setf n (- n 1)))
    (if n (logior #x100 (shl (- n 1) 4)) 0)))

(define-low power-init ()
  (when (and (logand (the :u32 (cpuid 1 :ecx)) 8) (logand (the :u32 (cpuid 6 :eax)) 4))
    (setf idle-hint (deepest-mwait)))
  (when (logand (the :u32 (cpuid 6 :eax)) (shl 1 7))
    (wrmsr +ia32-pm-enable+ 1)
    (let ((caps (rdmsr +ia32-hwp-capabilities+)))
      (wrmsr +ia32-hwp-request+
             (logior (logand (shr caps 24) 255) (shl (logand caps 255) 8)
                     (if (logand (the :u32 (cpuid 6 :eax)) (shl 1 10)) (shl +hwp-balanced+ 24) 0))))))

(define-low idle-wait ()
  (if idle-hint
      (progn
        (monitor (address idle-hint))
        (sti-mwait (logand idle-hint 255))
        (cli))
      (progn
        (sti)
        (hlt)
        (cli))))
