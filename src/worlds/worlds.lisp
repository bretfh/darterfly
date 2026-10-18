(defpackage #:darterfly/worlds
  (:use #:cl)
  (:export #:make-port #:receive #:reply #:call #:spawn #:stop #:world-state #:world-error #:free-pages #:spawn-record #:receive-into #:copy-from #:copy-into
           #:heartbeat #:*watchdog-limit* #:quiet-watchdog #:pause #:resume #:checkpoint #:restore #:grant-memory #:grant-vectors #:port-into))
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

(defvar *reply-buffer* nil)

(defun reply-buffer ()
  (or *reply-buffer* (setf *reply-buffer* (make-array +max-message+ :element-type '(unsigned-byte 8)))))

(defun call (port message)
  (let ((m (octets message))
        (r (if (eq sb-thread:*current-thread* (sb-thread:main-thread))
               (reply-buffer)
               (make-array 4096 :element-type '(unsigned-byte 8)))))
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

(defun grant-memory (world pa length &optional (kind :uncached))
  (machdep 62 world pa length (ecase kind (:memory 0) (:uncached 1) (:write-combining 2) (:reserve 3))))

(defun grant-vectors (world &rest vectors)
  (machdep 63 world (reduce #'logior vectors :key (lambda (v) (ash 1 (- v #x30))) :initial-value 0)))

(defun port-into (world)
  (let ((out (make-array 2 :element-type '(unsigned-byte 64))))
    (with-octets (o out) (machdep 64 world o))
    (values (aref out 0) (aref out 1))))

(defun pause (world) (machdep 53 world))

(defun resume (world) (machdep 54 world))

(defconstant +checkpoint-magic+ #x31504b4357464444)

(defun u64-octets (n) (let ((v (make-array 8 :element-type '(unsigned-byte 8)))) (dotimes (i 8 v) (setf (aref v i) (ldb (byte 8 (* 8 i)) n)))))

(defconstant +record-end+ #x444e45444f434552)

(defun checkpoint (world out &key full)
  (let ((describe (make-array (* 4 1048576) :element-type '(unsigned-byte 8)))
        (pages (make-array 4096 :element-type '(unsigned-byte 64)))
        (present (make-array 0 :element-type '(unsigned-byte 64) :adjustable t :fill-pointer t))
        (changed (make-array 0 :element-type '(unsigned-byte 64) :adjustable t :fill-pointer t))
        (data nil)
        (n-describe 0)
        (t0 (get-internal-real-time))
        (paused 0))
    (pause world)
    (unwind-protect
         (progn
           (setf n-describe (with-octets (d describe) (machdep 55 world d (length describe))))
           (let ((from 0))
             (loop
               (let ((n (with-octets (p pages) (machdep 56 world p (length pages) from))))
                 (dotimes (i n)
                   (let ((descriptor (aref pages i)))
                     (vector-push-extend descriptor present)
                     (when (or full (logtest descriptor 8)) (vector-push-extend descriptor changed))))
                 (setf from (aref pages (1- (length pages))))
                 (when (< n (1- (length pages))) (return)))))
           (setf data (make-array (* 4096 (length changed)) :element-type '(unsigned-byte 8)))
           (with-octets (b data)
             (loop :for descriptor :across changed :for at :from 0 :by 4096
                   :do (machdep 57 world (logand descriptor (lognot 4095)) (+ b at) 4096))))
      (resume world)
      (setf paused (- (get-internal-real-time) t0)))
    (write-sequence (u64-octets +checkpoint-magic+) out)
    (write-sequence (u64-octets n-describe) out)
    (write-sequence describe out :end n-describe)
    (write-sequence (u64-octets (length present)) out)
    (loop :for d :across present :do (write-sequence (u64-octets d) out))
    (write-sequence (u64-octets (length changed)) out)
    (loop :for d :across changed :for at :from 0 :by 4096
          :do (write-sequence (u64-octets d) out)
              (write-sequence data out :start at :end (+ at 4096)))
    (write-sequence (u64-octets +record-end+) out)
    (list :pages (length present) :written (length changed)
          :paused-ms (round (* 1000 paused) internal-time-units-per-second))))

(defun read-u64 (in) (let ((v (make-array 8 :element-type '(unsigned-byte 8)))) (read-sequence v in) (loop :for i :below 8 :sum (ash (aref v i) (* 8 i)))))

(defun read-count (in unit)
  (let ((n (read-u64 in)))
    (when (> (* n unit) (- (file-length in) (file-position in))) (error "torn"))
    n))

(defun read-records (in)
  (let ((describe nil) (present nil) (where (make-hash-table)))
    (loop
      (let ((start (file-position in)))
        (when (> (+ start 8) (file-length in)) (return))
        (unless (= (read-u64 in) +checkpoint-magic+) (return))
        (handler-case
            (let* ((d (let ((v (make-array (read-count in 1) :element-type '(unsigned-byte 8)))) (read-sequence v in) v))
                   (p (loop :repeat (read-count in 8) :collect (read-u64 in)))
                   (pages (loop :repeat (read-count in 4104)
                                :collect (let ((descriptor (read-u64 in)))
                                           (prog1 (cons (logand descriptor (lognot 4095)) (file-position in))
                                             (file-position in (+ (file-position in) 4096)))))))
              (unless (= (read-u64 in) +record-end+) (error "torn"))
              (setf describe d present p)
              (loop :for (va . at) :in pages :do (setf (gethash va where) at)))
          (error () (file-position in start) (return)))))
    (values describe present where)))

(defun restore (in base size port)
  (multiple-value-bind (describe present where) (read-records in)
    (unless describe (error "no complete checkpoint"))
    (let* ((n (length describe))
           (args (make-array 6 :element-type '(unsigned-byte 64)))
           (out (make-array 1 :element-type '(unsigned-byte 64)))
           (page (make-array 4096 :element-type '(unsigned-byte 8))))
      (with-octets (d describe)
        (with-octets (o out)
          (setf (aref args 0) d (aref args 1) n (aref args 2) base (aref args 3) size (aref args 4) port (aref args 5) o)
          (let ((world (with-octets (a args) (machdep 58 a))))
            (dolist (descriptor present)
              (let ((at (gethash (logand descriptor (lognot 4095)) where)))
                (when at
                  (file-position in at)
                  (read-sequence page in)
                  (with-octets (b page) (machdep 59 world descriptor b)))))
            (machdep 60 world d n)
            (values world (aref out 0))))))))

(defun world-state (world)
  (let ((flags (machdep 46 world)))
    (cond ((logtest flags 8) :gone) ((logtest flags 2) :stopped) ((logtest flags 4) :paused) (t :running))))
