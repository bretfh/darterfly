(in-package #:darterfly/libsa)

(defconstant +nsig+ 65)
(defconstant +sigaction-size+ 152)
(defconstant +einval+ 22)
(defconstant +esrch+ 3)
(defconstant +eintr+ 4)
(defconstant +enosys+ 38)
(defconstant +sa-siginfo+ 4)
(defconstant +sa-resethand+ #x80000000)

(define-global actions :u8 :count (* 65 152))

(define-low action-of ((sig :u32)) (+ (address actions) (* sig +sigaction-size+)))

(define-low bad-signal ((sig :u32))
  (or (= sig 0) (>= sig +nsig+)))

(define-low sigemptyset (s) (memset s 0 128) 0)
(define-low sigfillset (s) (memset s 255 128) 0)

(define-low sigaddset (s (sig :u32))
  (when (bad-signal sig)
    (setf (mem :u32 (__errno_location)) +einval+)
    (result (- 0 1)))
  (let ((at (+ s (* 8 (truncate (- sig 1) 64)))))
    (setf (mem :u64 at) (logior (mem :u64 at) (shl 1 (rem (- sig 1) 64)))))
  0)

(define-low sigdelset (s (sig :u32))
  (when (bad-signal sig)
    (setf (mem :u32 (__errno_location)) +einval+)
    (result (- 0 1)))
  (let ((at (+ s (* 8 (truncate (- sig 1) 64)))))
    (setf (mem :u64 at) (logand (mem :u64 at) (lognot (shl 1 (rem (- sig 1) 64))))))
  0)

(define-low sigismember (s (sig :u32))
  (when (bad-signal sig) (result 0))
  (logand (shr (mem :u64 (+ s (* 8 (truncate (- sig 1) 64)))) (rem (- sig 1) 64)) 1))

(define-low sigprocmask ((how :u32) set old)
  (when old (memset old 0 128))
  (__syscall 48 how set old 0 0 0))

(define-low pthread_sigmask ((how :u32) set old)
  (when old (memset old 0 128))
  (if (signed< (__syscall 329 how set old 0 0 0) 0)
      (mem :u32 (__errno_location))
      0))

(define-low sigpending (s) (sigemptyset s))

(define-low default-action ((sig :u32) info uc)
  (when (or (= sig 17) (= sig 28) (= sig 23) (= sig 18)) (result 0))
  (fprintf stderr "libsa: signal %d (%s) at %p, no handler
" sig (strsignal sig) (if info (mem :u64 (+ info 16)) 0))
  (_exit (+ 128 sig)))

(define-low _sigtramp ((sig :u32) info uc)
  (let* ((sa (action-of sig)) (handler (mem :u64 sa)))
    (cond ((= handler 0) (default-action sig info uc))
          ((= handler 1))
          ((logand (mem :u32 (+ sa 136)) +sa-siginfo+) (call-pointer handler sig info uc))
          (t (call-pointer handler sig)))
    (when (logand (mem :u32 (+ sa 136)) +sa-resethand+) (setf (mem :u64 sa) 0))
    (__syscall 184 uc 0 0 0 0 0)))

(define-low sigaction ((sig :u32) sa old)
  (when (bad-signal sig)
    (setf (mem :u32 (__errno_location)) +einval+)
    (result (- 0 1)))
  (when old (memcpy old (action-of sig) +sigaction-size+))
  (if sa
      (let ((block (malloc 32)) (r 0))
        (memcpy (action-of sig) sa +sigaction-size+)
        (setf (mem :u64 block) (mem :u64 sa))
        (setf (mem :u64 (+ block 8)) (code-address _sigtramp))
        (setf (mem :u64 (+ block 16)) (mem :u64 (+ sa 8)))
        (setf (mem :u64 (+ block 24)) (mem :u32 (+ sa 136)))
        (setf r (__syscall 46 sig block 0 0 0 0))
        (free block)
        r)
      0))

(define-low signal ((sig :u32) handler)
  (let ((sa (malloc (* 2 +sigaction-size+))) (r 0))
    (memset sa 0 +sigaction-size+)
    (setf (mem :u64 sa) handler)
    (setf r (if (signed< (sign-extend :u32 (sigaction sig sa (+ sa +sigaction-size+))) 0)
                (lognot 0)
                (mem :u64 (+ sa +sigaction-size+))))
    (free sa)
    r))

(define-low sigaltstack (ss old)
  (when old (memset old 0 24))
  0)

(define-low raise ((sig :u32)) (__syscall 37 1 sig 1 0 0 0))

(define-low kill ((pid :u32) (sig :u32))
  (when (or (= pid 1) (= pid 0) (= pid #xFFFFFFFF)) (result (raise sig)))
  (ret (call 57 (sign-extend :u32 pid) sig 0 0)))

(define-low killpg ((pg :u32) (sig :u32)) (kill pg sig))

(define-low sigsuspend (s) (__syscall 111 s 0 0 0 0 0))

(define-low sigwait (s sig) +enosys+)

(define-low strsignal ((sig :u32))
  (cond ((= sig 1) "Hangup") ((= sig 2) "Interrupt") ((= sig 3) "Quit") ((= sig 4) "Illegal instruction")
        ((= sig 5) "Trace/breakpoint trap") ((= sig 6) "Aborted") ((= sig 7) "Bus error")
        ((= sig 8) "Floating point exception") ((= sig 9) "Killed") ((= sig 10) "User defined signal 1")
        ((= sig 11) "Segmentation fault") ((= sig 12) "User defined signal 2") ((= sig 13) "Broken pipe")
        ((= sig 14) "Alarm clock") ((= sig 15) "Terminated")
        (t "Unknown signal")))
