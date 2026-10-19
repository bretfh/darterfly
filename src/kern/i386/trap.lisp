(in-package #:darterfly/kern)

(defconstant +sigill+ 4)
(defconstant +sigtrap+ 5)
(defconstant +sigbus+ 7)
(defconstant +sigfpe+ 8)
(defconstant +sigsegv+ 11)
(defconstant +r-rax+ 0)
(defconstant +r-rbx+ 8)
(defconstant +r-rcx+ 16)
(defconstant +r-rbp+ 48)
(defconstant +r-r8+ 56)
(defconstant +r-trapno+ 120)
(defconstant +r-err+ 128)

(define-low trap-type (trapno)
  (cond ((= trapno 0) "divide error") ((= trapno 1) "debug trap") ((= trapno 2) "NMI")
        ((= trapno 3) "breakpoint") ((= trapno 4) "overflow") ((= trapno 5) "bounds check")
        ((= trapno 6) "invalid opcode") ((= trapno 7) "no coprocessor") ((= trapno 8) "double fault")
        ((= trapno 9) "coprocessor overrun") ((= trapno 10) "invalid TSS") ((= trapno 11) "segment not present")
        ((= trapno 12) "stack bounds") ((= trapno 13) "general protection") ((= trapno 14) "page fault")
        ((= trapno 16) "coprocessor error") ((= trapno 17) "watchpoint") ((= trapno 18) "machine check")
        ((= trapno 19) "SSE floating point") (t "(reserved)")))

(define-low reg (regs offset) (mem :u64 (+ regs offset)))

(define-low kernel-address-p (a)
  (and (>= a #xFFFFFF0000000000) (not (logand a 7))))

(define-low print-callers (rbp)
  (let ((frame rbp) (n 0))
    (kprintf "callers:")
    (while (and (< n 12) (the :u32 (kernel-address-p frame)))
      (kprintf " 0x%lx" (mem :u64 (+ frame 8)))
      (setf frame (mem :u64 frame))
      (incf n))
    (kprintf "
")))

(define-low panic-trap (regs)
  (let ((cr2 (read-cr 2)))
    (print-callers (reg regs +r-rbp+))
    (panic "Kernel trap at 0x%016lx, type %lu=%s, registers:
CR0: 0x%016lx, CR2: 0x%016lx, CR3: 0x%016lx, CR4: 0x%016lx
RAX: 0x%016lx, RBX: 0x%016lx, RCX: 0x%016lx, RDX: 0x%016lx
RSP: 0x%016lx, RBP: 0x%016lx, RSI: 0x%016lx, RDI: 0x%016lx
R8:  0x%016lx, R9:  0x%016lx, R10: 0x%016lx, R11: 0x%016lx
R12: 0x%016lx, R13: 0x%016lx, R14: 0x%016lx, R15: 0x%016lx
RFL: 0x%016lx, RIP: 0x%016lx, CS:  0x%016lx, SS:  0x%016lx
Fault CR2: 0x%016lx, Error code: 0x%016lx, Fault CPU: 0x0
"
           (reg regs +r-rip+) (reg regs +r-trapno+) (trap-type (reg regs +r-trapno+))
           (read-cr 0) cr2 (read-cr 3) (read-cr 4)
           (reg regs +r-rax+) (reg regs +r-rbx+) (reg regs +r-rcx+) (reg regs +r-rdx+)
           (reg regs +r-rsp+) (reg regs +r-rbp+) (reg regs +r-rsi+) (reg regs +r-rdi+)
           (reg regs +r-r8+) (reg regs (+ +r-r8+ 8)) (reg regs (+ +r-r8+ 16)) (reg regs (+ +r-r8+ 24))
           (reg regs (+ +r-r8+ 32)) (reg regs (+ +r-r8+ 40)) (reg regs (+ +r-r8+ 48)) (reg regs (+ +r-r8+ 56))
           (reg regs +r-rflags+) (reg regs +r-rip+) (logand (reg regs +r-cs+) #xFFFF) (logand (reg regs +r-ss+) #xFFFF)
           cr2 (reg regs +r-err+))))

(define-low user-trap (regs)
  (let ((cr2 (read-cr 2))
        (trapno (reg regs +r-trapno+)))
    (cond ((= trapno #x80) (unix-syscall regs) (result 0))
          ((= trapno #x81) (mach-call regs) (result 0))
          ((= trapno #x82) (machdep-syscall regs) (result 0))
          ((= trapno 14)
           (when (the :u32 (vm-fault cr2 (reg regs +r-err+))) (result 0))
           (when (the :u32 (|platform_parse_boot_arg| "faulttrace"))
             (kprintf "[fault: thread 0x%lx rip 0x%lx cr2 0x%lx err 0x%lx r13 0x%lx rsp 0x%lx fs 0x%lx]
" (mem :u64 (+ (current-thread) +t-thread-id+)) (reg regs +r-rip+) cr2 (reg regs +r-err+)
                      (reg regs (+ +r-r8+ 40)) (reg regs +r-rsp+) (rdmsr #xC0000100)))
           (when (the :u32 (sendsig regs +sigsegv+ (if (logand (reg regs +r-err+) 1) 2 1) cr2)) (result 0)))
          ((or (= trapno 1) (= trapno 3))
           (when (the :u32 (sendsig regs +sigtrap+ 1 (reg regs +r-rip+))) (result 0)))
          ((= trapno 6)
           (when (the :u32 (sendsig regs +sigill+ 1 (reg regs +r-rip+))) (result 0)))
          ((= trapno 0)
           (when (the :u32 (sendsig regs +sigfpe+ 1 (reg regs +r-rip+))) (result 0)))
          ((= trapno 19)
           (when (the :u32 (sendsig regs +sigfpe+ 0 (reg regs +r-rip+))) (result 0)))
          ((or (= trapno 13) (= trapno 17))
           (when (the :u32 (sendsig regs (if (= trapno 13) +sigsegv+ +sigbus+) 0 0)) (result 0))))
    (unless (privileged)
      (kprintf "world 0x%lx stopped: %s at 0x%lx, address 0x%lx
" (current-world) (trap-type trapno) (reg regs +r-rip+) cr2)
      (native-exit (current-world)
                   (cond ((= trapno 6) +sigill+)
                         ((or (= trapno 0) (= trapno 19)) +sigfpe+)
                         ((or (= trapno 1) (= trapno 3)) +sigtrap+)
                         ((= trapno 17) 10) ; BSD wait-status SIGBUS
                         (t +sigsegv+))))
    (kprintf "user trap with no handler:
")
    (panic-trap regs)))

(define-low kernel-trap (regs)
  (process-pmap-updates)
  (serve-msr-request)
  (funnel-lock)
  (let ((user (= (logand (reg regs +r-cs+) 3) 3))
        (trapno (reg regs +r-trapno+)))
    (when (or (and (>= trapno #x20) (< trapno #x80)) (>= trapno #xD0))
      (setf (ref irq-counts trapno) (+ (ref irq-counts trapno) 1))
      (lapic-interrupt trapno)
      (when (and (= trapno #xDD)
                 (or user (/= (current-thread) (mem :u64 (+ (cpu-data) +c-idle-thread+)))))
        (bsd-proftick))
      (when user
        (sched-ast)
        (bsd-ast regs))
      (result 0))
    (when user
      (user-trap regs)
      (sched-ast)
      (bsd-ast regs)
      (result 0))
    (when (and (= trapno 14) (the :u32 (vm-fault (read-cr 2) (reg regs +r-err+))))
      (result 0))
    (panic-trap regs)))
