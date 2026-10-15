(in-package #:finch/pexpert)

(define-global |PE_boot_args| :u64 :extern t)

(defconstant +command-line+ 8)

(define-low |PE_parse_boot_arg| (name)
  (let ((s (+ |PE_boot_args| +command-line+)))
    (while (mem :u8 s)
      (while (= (mem :u8 s) 32) (incf s))
      (let ((n name))
        (while (and (mem :u8 n) (= (mem :u8 s) (mem :u8 n)))
          (incf s)
          (incf n))
        (when (and (= (mem :u8 n) 0) (or (= (mem :u8 s) 32) (= (mem :u8 s) 61) (= (mem :u8 s) 0)))
          (result 1)))
      (while (and (mem :u8 s) (/= (mem :u8 s) 32)) (incf s)))
    0))

(define-low |PE_parse_boot_argn| (name value)
  (let ((s (+ |PE_boot_args| +command-line+)))
    (while (mem :u8 s)
      (while (= (mem :u8 s) 32) (incf s))
      (let ((n name))
        (while (and (mem :u8 n) (= (mem :u8 s) (mem :u8 n)))
          (incf s)
          (incf n))
        (when (and (= (mem :u8 n) 0) (= (mem :u8 s) 61))
          (let ((v 0))
            (incf s)
            (while (and (>= (mem :u8 s) 48) (<= (mem :u8 s) 57))
              (setf v (+ (* v 10) (- (mem :u8 s) 48)))
              (incf s))
            (setf (mem :u32 value) v)
            (result 1))))
      (while (and (mem :u8 s) (/= (mem :u8 s) 32)) (incf s)))
    0))

(define-low |PE_halt| ()
  (outb #xF4 0)
  (while 1 (cli) (hlt)))

(define-global interrupt-pending :u64)

(define-low |PE_incoming_interrupt| ((vector :u32))
  (setf interrupt-pending (logior interrupt-pending (shl 1 (- vector #x30))))
  (thread-wakeup (address interrupt-pending) 1))

(define-low |PE_interrupt_wait| (mask deadline)
  (while 1
    (let ((fired (logand interrupt-pending mask)))
      (when fired
        (setf interrupt-pending (logand interrupt-pending (lognot fired)))
        (result fired))
      (when (/= (the :u32 (thread-wait (address interrupt-pending) deadline)) 0)
        (result 0)))))

(defun pexpert-object ()
  (package-object "FINCH/PEXPERT"))
