(defpackage #:darterfly/nyxt-wire
  (:use #:cl)
  (:export #:connection #:make-connection #:connection-fd #:connection-root
           #:send-packet #:receive-packet #:connect-local #:u32 #:words #:utf8
           #:text #:close-connection))
(in-package #:darterfly/nyxt-wire)
(defstruct connection fd root (lock (sb-thread:make-mutex :name "Nyxt wire")))
(defun u32 (v at)
  (loop for i below 4 sum (ash (aref v (+ at i)) (* i 8))))
(defun words (&rest values)
  (let ((v (make-array (* 4 (length values)) :element-type '(unsigned-byte 8))))
    (loop for n in values for at from 0 by 4 do
      (dotimes (i 4) (setf (aref v (+ at i)) (ldb (byte 8 (* i 8)) n)))) v))
(defun utf8 (s) (sb-ext:string-to-octets s :external-format :utf-8))
(defun text (v) (sb-ext:octets-to-string v :external-format :utf-8))
(defun raw-io (c v start end writep)
  (if (connection-root c)
      (if writep (darterfly/bsd:write (connection-fd c) (subseq v start end))
          (let ((bytes (darterfly/bsd:read (connection-fd c) (- end start))))
            (replace v bytes :start1 start) (length bytes)))
      (sb-sys:with-pinned-objects (v)
        (if writep
            (sb-alien:alien-funcall
             (sb-alien:extern-alien "write" (function sb-alien:long sb-alien:int
               sb-sys:system-area-pointer sb-alien:unsigned-long))
             (connection-fd c) (sb-sys:sap+ (sb-sys:vector-sap v) start) (- end start))
            (sb-alien:alien-funcall
             (sb-alien:extern-alien "read" (function sb-alien:long sb-alien:int
               sb-sys:system-area-pointer sb-alien:unsigned-long))
             (connection-fd c) (sb-sys:sap+ (sb-sys:vector-sap v) start) (- end start))))))
(defun world-io (c v start end writep)
  ;; Lisp WITHOUT-INTERRUPTS defers Lisp handlers, not the kernel signal which
  ;; interrupts a world RPC. Block signals only across this nonblocking call.
  ;; In particular, never let a GC stop abandon a read after it consumed bytes.
  (sb-sys:without-gcing
    (sb-sys:without-interrupts
      (sb-alien:with-alien ((blocked (array sb-alien:unsigned-char 128))
                           (previous (array sb-alien:unsigned-char 128)))
        (dotimes (i 128) (setf (sb-alien:deref blocked i) 255))
        (flet ((mask (how set old)
                 (sb-alien:alien-funcall
                  (sb-alien:extern-alien "pthread_sigmask"
                    (function sb-alien:int sb-alien:int
                      sb-sys:system-area-pointer sb-sys:system-area-pointer))
                  how set old)))
          (assert (zerop (mask 0 (sb-alien:alien-sap blocked)
                                (sb-alien:alien-sap previous))))
          (unwind-protect
              (let ((n (raw-io c v start end writep)))
                (values n (if (minusp n) (sb-alien:get-errno) 0)))
            (mask 2 (sb-alien:alien-sap previous) (sb-sys:int-sap 0))))))))
(defun transfer (c v writep)
  (loop with at = 0 while (< at (length v)) do
    (multiple-value-bind (n errno)
        (if (connection-root c)
            (raw-io c v at (min (length v) (+ at 32768)) writep)
            (world-io c v at (min (length v) (+ at 32768)) writep))
      (cond ((plusp n) (incf at n))
            ((and (minusp n) (= errno 4)) nil)
            ((and (minusp n) (= errno 11)) (sleep .005))
            (t (error "Nyxt fd ~d ~a failed: result ~d errno ~s"
                      (connection-fd c) (if writep "write" "read") n errno))))) v)
(defun send-packet (c op id &key (seq 0) (a 0) (b 0) (data #()))
  (let ((bytes (if (stringp data) (utf8 data)
                   (coerce data '(simple-array (unsigned-byte 8) (*))))))
    (assert (<= (length bytes) (* 16 1024 1024)))
    (sb-thread:with-mutex ((connection-lock c))
      (transfer c (words op id seq a b (length bytes)) t)
      (transfer c bytes t))))
(defun receive-packet (c)
  (let* ((h (transfer c (make-array 24 :element-type '(unsigned-byte 8)) nil))
         (n (u32 h 20)))
    (unless (<= n (* 16 1024 1024)) (error "Oversized Nyxt message on fd ~d: ~s" (connection-fd c) (loop for i below 24 by 4 collect (u32 h i))))
    (values (u32 h 0) (u32 h 4) (u32 h 8) (u32 h 12) (u32 h 16)
            (transfer c (make-array n :element-type '(unsigned-byte 8)) nil))))
(defun connect-local (path)
  (let ((addr (make-array 110 :element-type '(unsigned-byte 8) :initial-element 0)))
    (assert (< (length (utf8 path)) 108))
    (setf (aref addr 0) 1) (replace addr (utf8 path) :start1 2)
    (loop repeat 200
      for fd = (sb-alien:alien-funcall
                (sb-alien:extern-alien "socket" (function sb-alien:int
                  sb-alien:int sb-alien:int sb-alien:int)) 1 1 0)
      do (assert (>= fd 0))
         (let ((c (make-connection :fd fd)))
           (when (zerop (sb-sys:with-pinned-objects (addr)
             (sb-alien:alien-funcall
               (sb-alien:extern-alien "connect" (function sb-alien:int
                 sb-alien:int sb-sys:system-area-pointer sb-alien:unsigned))
               fd (sb-sys:vector-sap addr) 110)))
             (assert (zerop (sb-alien:alien-funcall
               (sb-alien:extern-alien "fcntl" (function sb-alien:int
                 sb-alien:int sb-alien:int sb-alien:int)) fd 4 #o4000)))
             (return-from connect-local c))
           (close-connection c))
         (sleep .05))
    (error "No Nyxt service at ~a" path)))
(defun close-connection (c)
  (if (connection-root c) (darterfly/bsd:close (connection-fd c))
      (sb-alien:alien-funcall
        (sb-alien:extern-alien "close" (function sb-alien:int sb-alien:int))
        (connection-fd c))))
