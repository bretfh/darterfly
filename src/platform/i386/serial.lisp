(defpackage #:finch/platform
  (:use #:cl #:finch/low)
  (:export #:platform-object))
(in-package #:finch/platform)

(defconstant +com1+ #x3F8)
(defconstant +lsr+ (+ +com1+ 5))
(defconstant +ier+ (+ +com1+ 1))

(define-global tx :u8 :count 65536 :alignment 64)
(define-global txhead :u32 :alignment 4)
(define-global txtail :u32 :alignment 4)
(define-global interrupts-on :u32 :alignment 4)
(define-global ring :u8 :count 4096 :alignment 64)
(define-global head :u32 :alignment 4)
(define-global tail :u32 :alignment 4)

(define-low serial-init ()
  (outb +ier+ #x00)
  (outb (+ +com1+ 3) #x80)
  (outb +com1+ #x01)
  (outb +ier+ #x00)
  (outb (+ +com1+ 3) #x03)
  (outb (+ +com1+ 2) #xC7)
  (outb (+ +com1+ 4) #x03))

(define-low serial-put-polled ((c :u8))
  (while (= (logand (inb +lsr+) #x20) 0))
  (outb +com1+ c))

(define-low serial-putc ((c :u8))
  (while (/= txhead txtail)
    (serial-put-polled (ref tx (logand txtail #xFFFF)))
    (incf txtail))
  (when (= c 10) (serial-put-polled 13))
  (serial-put-polled c)
  (console-putc c))

(define-low serial-tx-kick ()
  (while (and (/= txhead txtail) (/= (logand (inb +lsr+) #x20) 0))
    (let ((i 0))
      (while (and (< i 16) (/= txhead txtail))
        (outb +com1+ (ref tx (logand txtail #xFFFF)))
        (incf txtail)
        (incf i))))
  (when interrupts-on
    (outb +ier+ (if (/= txhead txtail) 3 1))))

(define-low serial-tx-room ()
  (< (logand (- txhead txtail) #xFFFFFFFF) (- 65536 2)))

(define-low serial-write ((c :u8))
  (if (not interrupts-on)
      (serial-putc c)
      (progn
        (when (= c 10)
          (setf (ref tx (logand txhead #xFFFF)) 13)
          (incf txhead))
        (setf (ref tx (logand txhead #xFFFF)) c)
        (incf txhead)
        (console-putc c))))

(define-low serial-enable-interrupts ()
  (outb +ier+ #x01)
  (outb (+ +com1+ 4) #x0B)
  (setf interrupts-on 1))

(define-low serial-interrupt ()
  (while (/= (logand (inb +lsr+) 1) 0)
    (let ((c (inb +com1+)))
      (if (= c 3)
          (bsd-console-interrupt-char)
          (when (< (logand (- head tail) #xFFFFFFFF) 4096)
            (setf (ref ring (logand head #xFFF)) c)
            (incf head)))))
  (serial-tx-kick))

(define-low serial-ready ()
  (if (not interrupts-on)
      (logand (inb +lsr+) 1)
      (/= head tail)))

(define-low serial-getc ()
  (if (not interrupts-on)
      (progn
        (while (= (logand (inb +lsr+) 1) 0) (pause))
        (inb +com1+))
      (if (= head tail)
          -1
          (let ((c (ref ring (logand tail #xFFF))))
            (incf tail)
            c))))

