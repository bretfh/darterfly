(in-package #:finch/test)

(def-suite boot :in all)
(in-suite boot)

(test boot-efi-starts-the-kernel
  (let ((c (image:bare-console :boot-args "halt")))
    (unwind-protect
         (progn
           (is (image:expect c "finch boot.efi"))
           (is (search "rsdp 0x" (image:expect c "boot-args \"halt\"")))
           (is (image:expect c "finch Kernel Version"))
           (is (image:expect c "boot_args: Revision 1 Version 2 efiMode 64"))
           (is (search "kslide 0x" (image:expect c "memory:")))
           (is (search "MB usable" (image:expect c "video: 1280x800x32")))
           (is (image:expect c (format nil "~%halt"))))
      (image:finish c 5))))

(test the-kernel-owns-the-machine
  (let ((c (image:bare-console :boot-args "trap halt")))
    (unwind-protect
         (progn
           (is (image:expect c "mp_desc: gdt, idt and ktss loaded"))
           (is (image:expect c "pmap: physmap"))
           (let ((panic (image:expect c "Error code")))
             (is (search "panic(cpu 0 caller 0x" panic))
             (is (search "Kernel trap at 0x" panic))
             (is (search "type 3=breakpoint" panic))
             (is (search "CS:  0x0000000000000008, SS:  0x0000000000000010" panic))))
      (image:finish c 5))))

(test the-kernel-has-memory
  (let ((c (image:bare-console :boot-args "vmtest halt")))
    (unwind-protect
         (progn
           (is (search "at 0xffff800000000000" (image:expect c "kernel at 0xffffffff80000000")))
           (is (image:expect c "vmtest: 512 demand-zero pages, 512 read back"))
           (is (image:expect c "vmtest: kalloc reuses freed blocks")))
      (image:finish c 5))))

(test sbcl-runs-on-finch
  (let ((c (image:bare-console)))
    (flet ((ask (form) (image:send c form) (image:expect c (format nil "~%* ") :timeout 60)))
      (unwind-protect
           (progn
             (is (image:expect c "load_init_program: sbcl"))
             (is (image:expect c "* " :timeout 60))
             (is (search "\"2.6.4.finch\"" (ask "(lisp-implementation-version)")))
             (is (search "200000000" (ask "(let ((n 0)) (dotimes (i 200) (incf n (length (make-array 1000000)))) n)")))
             (ask "(gc :full t)")
             (is (search "3000000" (ask "(length (loop repeat 3000000 collect (cons 1 2)))")))
             (image:send c "(car 1)")
             (is (search "is not of type" (image:expect c "0] " :timeout 30)))
             (image:send c ":abort")
             (image:expect c "* " :timeout 30)
             (ask "(defun fib (n) (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2)))))")
             (is (search "832040" (ask "(fib 30)")))
             (is (search "T" (ask "(> (get-universal-time) 3960000000)")))
             (image:send c "(sb-ext:exit :code 7)")
             (is (image:expect c "exit(7)" :timeout 30)))
        (image:finish c 5)))))

(test interrupts-reach-lisp
  (let ((c (image:bare-console)))
    (flet ((ask (form) (image:send c form) (image:expect c (format nil "~%* ") :timeout 30)))
      (unwind-protect
           (progn
             (is (search "lapic: timer" (image:expect c "load_init_program: sbcl")))
             (image:expect c "* " :timeout 60)
             (let ((slept (ask "(let ((s (get-internal-real-time))) (sleep 0.5) (- (get-internal-real-time) s))")))
               (is (<= 500000 (parse-integer slept :junk-allowed t :start (position-if #'digit-char-p slept)) 600000)))
             (ask "(defvar *n* 0)")
             (ask "(progn (sb-ext:schedule-timer (sb-ext:make-timer (lambda () (incf *n*))) 0.05 :repeat-interval 0.05) :scheduled)")
             (let ((n (ask "(progn (sleep 1) *n*)")))
               (is (<= 18 (parse-integer n :junk-allowed t :start (position-if #'digit-char-p n)) 22) "~s" n))
             (image:send c "(loop)")
             (sleep 0.5)
             (image:send-char c (code-char 3))
             (is (search "INTERACTIVE-INTERRUPT" (image:expect c "0] " :timeout 30)))
             (image:send c ":abort")
             (image:expect c "* " :timeout 30)
             (is (search "3" (ask "(+ 1 2)"))))
        (image:finish c 5)))))

(test threads-on-finch
  (let ((c (image:bare-console)))
    (flet ((ask (form) (image:send c form) (image:expect c (format nil "~%* ") :timeout 60)))
      (unwind-protect
           (progn
             (image:expect c "* " :timeout 60)
             (is (search ":SB-THREAD" (ask "(find :sb-thread *features*)")))
             (is (search "3" (ask "(sb-thread:join-thread (sb-thread:make-thread (lambda () (+ 1 2))))")))
             (is (search "(0 1000000 2000000 3000000)"
                         (ask "(let ((ts (loop for i below 4 collect (let ((i i)) (sb-thread:make-thread (lambda () (loop repeat 1000000 sum i))))))) (mapcar #'sb-thread:join-thread ts))")))
             (is (search "80000"
                         (ask "(let ((m (sb-thread:make-mutex)) (n 0)) (mapc #'sb-thread:join-thread (loop repeat 4 collect (sb-thread:make-thread (lambda () (dotimes (i 20000) (sb-thread:with-mutex (m) (incf n))))))) n)")))
             (is (search "(30000000 30000000 30000000)"
                         (ask "(let ((ts (loop repeat 3 collect (sb-thread:make-thread (lambda () (let ((n 0)) (dotimes (i 300) (incf n (length (make-array 100000)))) n)))))) (mapcar #'sb-thread:join-thread ts))"))))
        (image:finish c 5)))))

(test xnu-checked-suites-pass-on-finch
  (let ((c (image:bare-console)))
    (flet ((ask (form) (image:send c form) (image:expect c (format nil "~%* ") :timeout 300)))
      (unwind-protect
           (progn
             (image:expect c "* " :timeout 60)
             (is (search "334" (ask "(length (uiop:read-file-lines \"/finch/tests/ports.txt\"))")))
             (is (search "(T T)"
                         (ask "(list (fiveam:results-status (fiveam:run 'finch/test::mach)) (fiveam:results-status (fiveam:run 'finch/test::bsd)))"))))
        (image:finish c 5)))))
