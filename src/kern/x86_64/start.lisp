(in-package #:darterfly/kern)

(eval-when (:compile-toplevel :load-toplevel :execute)
(defun layout (items)
  (let ((labels (make-hash-table)) (out nil))
    (dotimes (pass 2)
      (let ((at 0))
        (setf out nil)
        (dolist (item items)
          (flet ((emit (&rest octets) (dolist (o octets) (push o out) (incf at))))
            (cond ((integerp item) (emit item))
                  ((eq (first item) :label) (setf (gethash (second item) labels) at))
                  ((eq (first item) :align) (loop :until (zerop (mod at (second item))) :do (emit 0)))
                  (t (destructuring-bind (kind value) item
                       (let ((v (if (symbolp value) (gethash value labels 0) value)))
                         (dotimes (i (ecase kind (:d16 2) (:d32 4) (:q 8)))
                           (emit (ldb (byte 8 (* 8 i)) v)))))))))))
    (values (coerce (nreverse out) '(vector (unsigned-byte 8))) labels)))

(defparameter +trampoline+
  `(#xFA #x8C #xC8 #x8E #xD8 #x8E #xD0 #xBC #x00 #x10
    #x66 #x31 #xDB #x8C #xCB #x66 #xC1 #xE3 #x04
    #x67 #x66 #x8D #x83 (:d32 gdt)
    #x66 #xA3 (:d16 gdtr+2)
    #x66 #x0F #x01 #x16 (:d16 gdtr)
    #x0F #x20 #xC0 #x66 #x83 #xC8 #x01 #x0F #x22 #xC0
    #x67 #x66 #x8D #x83 (:d32 protected)
    #x66 #x6A #x08 #x66 #x50 #x66 #xCB
    (:label protected)
    #x66 #xB8 #x10 #x00 #x8E #xD8 #x8E #xC0 #x8E #xD0
    #x8D #xA3 #x00 #x10 #x00 #x00
    #x0F #x20 #xE0 #x83 #xC8 #x20 #x0F #x22 #xE0
    #x8B #x83 (:d32 cr3) #x0F #x22 #xD8
    #xB9 #x80 #x00 #x00 #xC0 #x0F #x32 #x0D #x00 #x09 #x00 #x00 #x0F #x30
    #x0F #x20 #xC0 #x0D #x00 #x00 #x00 #x80 #x0F #x22 #xC0
    #x8D #x83 (:d32 long) #x6A #x18 #x50 #xCB
    (:label long)
    #x89 #xDB
    #x48 #x8B #xA3 (:d32 rsp)
    #x48 #x8B #xBB (:d32 cpu)
    #x48 #x8B #x83 (:d32 entry)
    #xFF #xE0
    (:align 8)
    (:label gdt)
    (:q 0) (:q #x00CF9A000000FFFF) (:q #x00CF92000000FFFF) (:q #x00209A0000000000)
    (:label gdtr) (:d16 31) (:label gdtr+2) (:d32 0)
    (:align 8)
    (:label cr3) (:q 0)
    (:label rsp) (:q 0)
    (:label cpu) (:q 0)
    (:label entry) (:q 0)))

(defun trampoline-offset (name)
  (multiple-value-bind (bytes labels) (layout +trampoline+)
    (declare (ignore bytes))
    (gethash name labels))))

(defconstant +slave-cr3+ (trampoline-offset 'cr3))
(defconstant +slave-rsp+ (trampoline-offset 'rsp))
(defconstant +slave-cpu+ (trampoline-offset 'cpu))
(defconstant +slave-entry+ (trampoline-offset 'entry))
(defconstant +slave-size+ (length (layout +trampoline+)))

(define-global stack :u8 :count 65536 :alignment 16)

(defun start-routines ()
  (list
   (darterfly/asm:routine "_start"
     (darterfly/asm:inst byte #xFA)
     (darterfly/asm:inst lea darterfly/asm:rsp-tn (darterfly/asm:rip-relative-ea (sb-c:make-fixup "stack" :foreign-dataref 65536)))
     (darterfly/asm:inst xor :dword (darterfly/asm:reg :dword 5) (darterfly/asm:reg :dword 5))
     (darterfly/asm:inst call (darterfly/asm:external "i386_init"))
     halt
     (darterfly/asm:inst byte #xF4)
     (darterfly/asm:inst jmp halt))
   (darterfly/asm:routine "slave_boot_base"
     (loop :for b :across (layout +trampoline+) :do (darterfly/asm:inst byte b)))
   (darterfly/asm:routine "libsa_start_address"
     (darterfly/asm:quad "_libsa_start"))))
