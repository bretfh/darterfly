(defpackage #:darterfly/worlds
  (:use #:cl)
  (:export #:make-port #:receive #:reply #:call #:spawn #:stop #:world-state #:world-error #:free-pages #:spawn-record #:receive-into #:copy-from #:copy-into
           #:heartbeat #:*watchdog-limit* #:quiet-watchdog #:pause #:resume #:checkpoint #:restore))
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

(defvar *watchdog-limit* 30)

(defun heartbeat ()
  (loop (machdep 52 *watchdog-limit*) (sleep 1)))

(defun quiet-watchdog () (machdep 52 0))

(defun pause (world) (machdep 53 world))

(defun resume (world) (machdep 54 world))

(defconstant +checkpoint-magic+ #x31504b4357464444)

(defun u64-octets (n) (let ((v (make-array 8 :element-type '(unsigned-byte 8)))) (dotimes (i 8 v) (setf (aref v i) (ldb (byte 8 (* 8 i)) n)))))

(defun checkpoint (world out)
  (let ((describe (make-array (* 4 1048576) :element-type '(unsigned-byte 8)))
        (pages (make-array 4096 :element-type '(unsigned-byte 64)))
        (page (make-array 4096 :element-type '(unsigned-byte 8)))
        (count 0)
        (t0 (get-internal-real-time)))
    (pause world)
    (unwind-protect
         (progn
           (let ((n (with-octets (d describe) (machdep 55 world d (length describe)))))
             (write-sequence (u64-octets +checkpoint-magic+) out)
             (write-sequence (u64-octets n) out)
             (write-sequence describe out :end n))
           (let ((from 0))
             (loop
               (let ((n (with-octets (p pages) (machdep 56 world p (length pages) from))))
                 (dotimes (i n)
                   (let ((descriptor (aref pages i)))
                     (with-octets (b page) (machdep 57 world (logand descriptor (lognot 4095)) b 4096))
                     (write-sequence (u64-octets descriptor) out)
                     (write-sequence page out)
                     (incf count)))
                 (setf from (aref pages (1- (length pages))))
                 (when (< n (1- (length pages))) (return)))))
           (write-sequence (u64-octets 0) out))
      (resume world))
    (list :pages count :paused-ms (round (* 1000 (- (get-internal-real-time) t0)) internal-time-units-per-second))))

(defun read-u64 (in) (let ((v (make-array 8 :element-type '(unsigned-byte 8)))) (read-sequence v in) (loop :for i :below 8 :sum (ash (aref v i) (* 8 i)))))

(defun restore (in base size port)
  (unless (= (read-u64 in) +checkpoint-magic+) (error "not a world checkpoint"))
  (let* ((n (read-u64 in))
         (describe (make-array n :element-type '(unsigned-byte 8)))
         (args (make-array 6 :element-type '(unsigned-byte 64)))
         (out (make-array 1 :element-type '(unsigned-byte 64)))
         (page (make-array 4096 :element-type '(unsigned-byte 8))))
    (read-sequence describe in)
    (with-octets (d describe)
      (with-octets (o out)
        (setf (aref args 0) d (aref args 1) n (aref args 2) base (aref args 3) size (aref args 4) port (aref args 5) o)
        (let ((world (with-octets (a args) (machdep 58 a))))
          (loop :for descriptor := (read-u64 in)
                :until (zerop descriptor)
                :do (read-sequence page in)
                    (with-octets (b page) (machdep 59 world descriptor b)))
          (machdep 60 world d n)
          (values world (aref out 0)))))))

(defun world-state (world)
  (let ((flags (machdep 46 world)))
    (cond ((logtest flags 8) :gone) ((logtest flags 2) :stopped) ((logtest flags 4) :paused) (t :running))))
