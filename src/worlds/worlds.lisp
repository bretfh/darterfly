(defpackage #:darterfly/worlds
  (:use #:cl)
  (:export #:make-port #:receive #:reply #:call #:spawn #:stop #:world-state #:world-error #:free-pages #:spawn-record #:receive-into #:copy-from #:copy-into))
(in-package #:darterfly/worlds)

(define-condition world-error (error)
  ((code :initarg :code :reader world-error-code))
  (:report (lambda (c s) (format s "world call failed with errno ~d" (world-error-code c)))))

(defconstant +max-message+ 65536)

(defun machdep (n &optional (a 0) (b 0) (c 0) (d 0) (e 0))
  (let ((r (sb-alien:alien-funcall
            (sb-alien:extern-alien "__machdep5" (function sb-alien:long sb-alien:long sb-alien:unsigned-long sb-alien:unsigned-long
                                                          sb-alien:unsigned-long sb-alien:unsigned-long sb-alien:unsigned-long))
            n a b c d e)))
    (if (minusp r) (error 'world-error :code (- r)) r)))

(defmacro with-octets ((sap vector) &body body)
  `(sb-sys:with-pinned-objects (,vector)
     (let ((,sap (sb-sys:sap-int (sb-sys:vector-sap ,vector))))
       ,@body)))

(defun octets (x)
  (if (stringp x) (sb-ext:string-to-octets x :external-format :utf-8) (coerce x '(simple-array (unsigned-byte 8) (*)))))

(defun make-port () (machdep 40))

(defun call (port message)
  (let ((m (octets message))
        (r (make-array +max-message+ :element-type '(unsigned-byte 8))))
    (with-octets (ms m)
      (with-octets (rs r)
        (subseq r 0 (machdep 41 port ms (length m) rs (length r)))))))

(defun receive (port &key (timeout 0))
  (let ((buf (make-array +max-message+ :element-type '(unsigned-byte 8)))
        (out (make-array 3 :element-type '(unsigned-byte 64))))
    (with-octets (bs buf)
      (with-octets (os out)
        (let ((n (machdep 42 port bs (length buf) os (round (* timeout 1000000)))))
          (values (subseq buf 0 n) (aref out 0) (aref out 2)))))))

(defun receive-into (port buffer &key (timeout 0))
  (let ((out (make-array 3 :element-type '(unsigned-byte 64))))
    (with-octets (bs buffer)
      (with-octets (os out)
        (let ((n (machdep 42 port bs (length buffer) os (round (* timeout 1000000)))))
          (values n (aref out 0) (aref out 2)))))))

(defun copy-from (token there here size) (machdep 49 token there size here))

(defun copy-into (token there here size) (machdep 50 token there size here))

(defun reply (token message)
  (let ((m (octets message)))
    (with-octets (ms m)
      (machdep 43 token ms (length m)))))

(defun spawn (program &key (entry 0) port)
  (let ((p (octets program)))
    (with-octets (ps p)
      (machdep 44 ps (length p) entry (or port 0)))))

(defun stop (world) (machdep 45 world))

(defun spawn-record (base size port)
  (let ((out (make-array 1 :element-type '(unsigned-byte 64) :initial-element 0)))
    (with-octets (os out)
      (values (machdep 48 base size port os) (aref out 0)))))

(defun free-pages () (machdep 47))

(defun world-state (world)
  (let ((flags (machdep 46 world)))
    (cond ((logtest flags 4) :gone) ((logtest flags 2) :stopped) (t :running))))
