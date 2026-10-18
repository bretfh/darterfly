(in-package #:darterfly/kern)

(defparameter +error-vectors+ '(8 10 11 12 13 14 17 21 29 30))
(defparameter +trap-vectors+
  (append (loop :for v :below #x30 :collect v) '(#x80 #x81 #x82)
          (loop :for v :from #x30 :below #x40 :collect v) '(#xDA #xDD #xDE)))

(defun trap-name (vector)
  (if (< vector 32) (format nil "trap_~d" vector) (format nil "trap_0x~(~x~)" vector)))

(defmacro bytes (&rest octets) `(progn ,@(mapcar (lambda (b) `(darterfly/asm:inst byte ,b)) octets)))

(defun push-immediate (value)
  (darterfly/asm:inst byte #x68)
  (dotimes (i 4) (darterfly/asm:inst byte (ldb (byte 8 (* 8 i)) value))))

(defparameter +saved-registers+
  '(darterfly/asm:r15-tn darterfly/asm:r14-tn darterfly/asm:r13-tn darterfly/asm:r12-tn darterfly/asm:r11-tn darterfly/asm:r10-tn
    darterfly/asm:r9-tn darterfly/asm:r8-tn darterfly/asm:rbp-tn darterfly/asm:rdi-tn darterfly/asm:rsi-tn darterfly/asm:rdx-tn
    darterfly/asm:rcx-tn darterfly/asm:rbx-tn darterfly/asm:rax-tn))

(defparameter +callee-saved+
  '(darterfly/asm:rbp-tn darterfly/asm:rbx-tn darterfly/asm:r12-tn darterfly/asm:r13-tn darterfly/asm:r14-tn darterfly/asm:r15-tn))

(defun trap-stub (vector)
  (darterfly/asm:routine (trap-name vector)
    (unless (member vector +error-vectors+) (push-immediate 0))
    (push-immediate vector)
    (darterfly/asm:inst jmp (darterfly/asm:external "trap_common"))))

(defun stub-routines ()
  (append
   (mapcar #'trap-stub +trap-vectors+)
   (list
    (darterfly/asm:routine "trap_common"
      (dolist (r +saved-registers+) (darterfly/asm:inst push (symbol-value r)))
      (darterfly/asm:inst mov darterfly/asm:rdi-tn darterfly/asm:rsp-tn)
      (darterfly/asm:inst call (darterfly/asm:external "kernel_trap"))
      (darterfly/asm:inst jmp (darterfly/asm:external "return_to_user")))
    (darterfly/asm:routine "return_to_user"
      (darterfly/asm:inst call (darterfly/asm:external "funnel_unlock"))
      (dolist (r (reverse +saved-registers+)) (darterfly/asm:inst pop (symbol-value r)))
      (darterfly/asm:inst add darterfly/asm:rsp-tn 16)
      (bytes #x48 #xCF))
    (darterfly/asm:routine "sleep_save"
      (loop :for r :in +callee-saved+ :for at :from 0 :by 8
            :do (darterfly/asm:inst mov (darterfly/asm:ea at darterfly/asm:rdi-tn) (symbol-value r)))
      (darterfly/asm:inst lea darterfly/asm:rdx-tn (darterfly/asm:ea 8 darterfly/asm:rsp-tn))
      (darterfly/asm:inst mov (darterfly/asm:ea 48 darterfly/asm:rdi-tn) darterfly/asm:rdx-tn)
      (darterfly/asm:inst mov darterfly/asm:rdx-tn (darterfly/asm:ea 0 darterfly/asm:rsp-tn))
      (darterfly/asm:inst mov (darterfly/asm:ea 56 darterfly/asm:rdi-tn) darterfly/asm:rdx-tn)
      (darterfly/asm:inst xor :dword (darterfly/asm:reg :dword 0) (darterfly/asm:reg :dword 0))
      (darterfly/asm:inst ret))
    (darterfly/asm:routine "sleep_restore"
      (loop :for r :in +callee-saved+ :for at :from 0 :by 8
            :do (darterfly/asm:inst mov (symbol-value r) (darterfly/asm:ea at darterfly/asm:rdi-tn)))
      (darterfly/asm:inst mov darterfly/asm:rsp-tn (darterfly/asm:ea 48 darterfly/asm:rdi-tn))
      (darterfly/asm:inst mov :dword (darterfly/asm:reg :dword 0) 1)
      (darterfly/asm:inst jmp (darterfly/asm:ea 56 darterfly/asm:rdi-tn)))
    (darterfly/asm:routine "Switch_context"
      (dolist (r +callee-saved+) (darterfly/asm:inst push (symbol-value r)))
      (darterfly/asm:inst mov (darterfly/asm:ea 0 darterfly/asm:rdi-tn) darterfly/asm:rsp-tn)
      (darterfly/asm:inst mov darterfly/asm:rsp-tn darterfly/asm:rsi-tn)
      (dolist (r (reverse +callee-saved+)) (darterfly/asm:inst pop (symbol-value r)))
      (darterfly/asm:inst ret))
    (darterfly/asm:routine "gdt_load"
      (bytes #x0F #x01 #x17)
      (bytes #x66 #xB8 #x10 #x00)
      (bytes #x8E #xD8 #x8E #xC0 #x8E #xD0)
      (bytes #x66 #x31 #xC0)
      (bytes #x8E #xE0 #x8E #xE8)
      (darterfly/asm:inst pop darterfly/asm:rax-tn)
      (push-immediate 8)
      (darterfly/asm:inst push darterfly/asm:rax-tn)
      (bytes #x48 #xCB))
    (darterfly/asm:routine "thread_bootstrap_return"
      (bytes #x66 #xB8 #x2B #x00)
      (bytes #x8E #xD8 #x8E #xC0)
      (push-immediate #x2B)
      (darterfly/asm:inst push darterfly/asm:rsi-tn)
      (push-immediate #x202)
      (push-immediate #x33)
      (darterfly/asm:inst push darterfly/asm:rdi-tn)
      (darterfly/asm:inst mov darterfly/asm:rdi-tn darterfly/asm:rdx-tn)
      (dolist (n '(6 2 0 3 1 5 8 9 10 11 12 13 14 15))
        (darterfly/asm:inst xor :dword (darterfly/asm:reg :dword n) (darterfly/asm:reg :dword n)))
      (bytes #x48 #xCF)))))
