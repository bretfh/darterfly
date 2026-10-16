(in-package #:finch/osfmk)

(defparameter +error-vectors+ '(8 10 11 12 13 14 17 21 29 30))
(defparameter +trap-vectors+
  (append (loop :for v :below #x30 :collect v) '(#x80 #x81 #x82)
          (loop :for v :from #x30 :below #x40 :collect v) '(#xDA #xDD #xDE)))

(defun trap-name (vector)
  (if (< vector 32) (format nil "trap_~d" vector) (format nil "trap_0x~(~x~)" vector)))

(defmacro bytes (&rest octets) `(progn ,@(mapcar (lambda (b) `(finch/asm:inst byte ,b)) octets)))

(defun push-immediate (value)
  (finch/asm:inst byte #x68)
  (dotimes (i 4) (finch/asm:inst byte (ldb (byte 8 (* 8 i)) value))))

(defparameter +saved-registers+
  '(finch/asm:r15-tn finch/asm:r14-tn finch/asm:r13-tn finch/asm:r12-tn finch/asm:r11-tn finch/asm:r10-tn
    finch/asm:r9-tn finch/asm:r8-tn finch/asm:rbp-tn finch/asm:rdi-tn finch/asm:rsi-tn finch/asm:rdx-tn
    finch/asm:rcx-tn finch/asm:rbx-tn finch/asm:rax-tn))

(defparameter +callee-saved+
  '(finch/asm:rbp-tn finch/asm:rbx-tn finch/asm:r12-tn finch/asm:r13-tn finch/asm:r14-tn finch/asm:r15-tn))

(defun trap-stub (vector)
  (finch/asm:routine (trap-name vector)
    (unless (member vector +error-vectors+) (push-immediate 0))
    (push-immediate vector)
    (finch/asm:inst jmp (finch/asm:external "trap_common"))))

(defun stub-routines ()
  (append
   (mapcar #'trap-stub +trap-vectors+)
   (list
    (finch/asm:routine "trap_common"
      (dolist (r +saved-registers+) (finch/asm:inst push (symbol-value r)))
      (finch/asm:inst mov finch/asm:rdi-tn finch/asm:rsp-tn)
      (finch/asm:inst call (finch/asm:external "kernel_trap"))
      (finch/asm:inst jmp (finch/asm:external "return_to_user")))
    (finch/asm:routine "return_to_user"
      (finch/asm:inst call (finch/asm:external "funnel_unlock"))
      (dolist (r (reverse +saved-registers+)) (finch/asm:inst pop (symbol-value r)))
      (finch/asm:inst add finch/asm:rsp-tn 16)
      (bytes #x48 #xCF))
    (finch/asm:routine "Switch_context"
      (dolist (r +callee-saved+) (finch/asm:inst push (symbol-value r)))
      (finch/asm:inst mov (finch/asm:ea 0 finch/asm:rdi-tn) finch/asm:rsp-tn)
      (finch/asm:inst mov finch/asm:rsp-tn finch/asm:rsi-tn)
      (dolist (r (reverse +callee-saved+)) (finch/asm:inst pop (symbol-value r)))
      (finch/asm:inst ret))
    (finch/asm:routine "gdt_load"
      (bytes #x0F #x01 #x17)
      (bytes #x66 #xB8 #x10 #x00)
      (bytes #x8E #xD8 #x8E #xC0 #x8E #xD0)
      (bytes #x66 #x31 #xC0)
      (bytes #x8E #xE0 #x8E #xE8)
      (finch/asm:inst pop finch/asm:rax-tn)
      (push-immediate 8)
      (finch/asm:inst push finch/asm:rax-tn)
      (bytes #x48 #xCB))
    (finch/asm:routine "thread_bootstrap_return"
      (bytes #x66 #xB8 #x2B #x00)
      (bytes #x8E #xD8 #x8E #xC0)
      (push-immediate #x2B)
      (finch/asm:inst push finch/asm:rsi-tn)
      (push-immediate #x202)
      (push-immediate #x33)
      (finch/asm:inst push finch/asm:rdi-tn)
      (finch/asm:inst mov finch/asm:rdi-tn finch/asm:rdx-tn)
      (dolist (n '(6 2 0 3 1 5 8 9 10 11 12 13 14 15))
        (finch/asm:inst xor :dword (finch/asm:reg :dword n) (finch/asm:reg :dword n)))
      (bytes #x48 #xCF)))))
