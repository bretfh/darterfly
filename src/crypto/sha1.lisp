(defpackage #:darterfly/crypto
  (:use #:cl)
  (:export #:octets #:sha1 #:hmac-sha1 #:pbkdf2-sha1 #:prf-sha1
           #:aes-key #:aes-encrypt-block #:aes-decrypt-block #:aes-wrap #:aes-unwrap
           #:random-octets))
(in-package #:darterfly/crypto)

(deftype octet-vector () '(simple-array (unsigned-byte 8) (*)))

(defun octets (&rest parts)
  (let ((out (make-array (reduce #'+ parts :key (lambda (p) (if (integerp p) 1 (length p))))
                         :element-type '(unsigned-byte 8)))
        (at 0))
    (dolist (p parts out)
      (etypecase p
        (integer (setf (aref out at) p) (incf at))
        (string (loop for c across p do (setf (aref out at) (char-code c)) (incf at)))
        (sequence (replace out p :start1 at) (incf at (length p)))))))

(declaim (inline rol32 u32be))
(defun rol32 (x n)
  (declare (type (unsigned-byte 32) x) (type (integer 0 31) n))
  (ldb (byte 32 0) (logior (ash x n) (ash x (- n 32)))))

(defun u32be (v i)
  (logior (ash (aref v i) 24) (ash (aref v (+ i 1)) 16) (ash (aref v (+ i 2)) 8) (aref v (+ i 3))))

(defun sha1-block (h block start w)
  (declare (type (simple-array (unsigned-byte 32) (5)) h)
           (type (simple-array (unsigned-byte 32) (80)) w)
           (type octet-vector block) (type fixnum start))
  (dotimes (i 16) (setf (aref w i) (u32be block (+ start (* 4 i)))))
  (loop for i from 16 below 80
        do (setf (aref w i) (rol32 (logxor (aref w (- i 3)) (aref w (- i 8)) (aref w (- i 14)) (aref w (- i 16))) 1)))
  (let ((a (aref h 0)) (b (aref h 1)) (c (aref h 2)) (d (aref h 3)) (e (aref h 4)))
    (declare (type (unsigned-byte 32) a b c d e))
    (dotimes (i 80)
      (multiple-value-bind (f k)
          (cond ((< i 20) (values (logior (logand b c) (logand (logxor b #xFFFFFFFF) d)) #x5A827999))
                ((< i 40) (values (logxor b c d) #x6ED9EBA1))
                ((< i 60) (values (logior (logand b c) (logand b d) (logand c d)) #x8F1BBCDC))
                (t (values (logxor b c d) #xCA62C1D6)))
        (let ((temp (ldb (byte 32 0) (+ (rol32 a 5) f e k (aref w i)))))
          (setf e d d c c (rol32 b 30) b a a temp))))
    (setf (aref h 0) (ldb (byte 32 0) (+ (aref h 0) a))
          (aref h 1) (ldb (byte 32 0) (+ (aref h 1) b))
          (aref h 2) (ldb (byte 32 0) (+ (aref h 2) c))
          (aref h 3) (ldb (byte 32 0) (+ (aref h 3) d))
          (aref h 4) (ldb (byte 32 0) (+ (aref h 4) e)))))

(defun sha1 (&rest parts)
  (let* ((message (apply #'octets parts))
         (length (length message))
         (padded (make-array (* 64 (ceiling (+ length 9) 64)) :element-type '(unsigned-byte 8) :initial-element 0))
         (h (make-array 5 :element-type '(unsigned-byte 32)
                          :initial-contents '(#x67452301 #xEFCDAB89 #x98BADCFE #x10325476 #xC3D2E1F0)))
         (w (make-array 80 :element-type '(unsigned-byte 32)))
         (digest (make-array 20 :element-type '(unsigned-byte 8))))
    (replace padded message)
    (setf (aref padded length) #x80)
    (loop for i from 0 below 8
          do (setf (aref padded (- (length padded) 1 i)) (ldb (byte 8 (* 8 i)) (* 8 length))))
    (loop for start from 0 below (length padded) by 64
          do (sha1-block h padded start w))
    (dotimes (i 20 digest)
      (setf (aref digest i) (ldb (byte 8 (- 24 (* 8 (mod i 4)))) (aref h (floor i 4)))))))

(defun hmac-sha1 (key &rest parts)
  (let* ((key (if (> (length key) 64) (sha1 key) (octets key)))
         (block (replace (make-array 64 :element-type '(unsigned-byte 8) :initial-element 0) key)))
    (sha1 (map 'octet-vector (lambda (b) (logxor b #x5C)) block)
          (apply #'sha1 (map 'octet-vector (lambda (b) (logxor b #x36)) block) parts))))

(defun pbkdf2-sha1 (password salt iterations length)
  (let ((password (octets password)) (salt (octets salt)))
    (subseq (apply #'octets
                   (loop for i from 1 to (ceiling length 20)
                         collect (let* ((u (hmac-sha1 password salt (ldb (byte 8 24) i) (ldb (byte 8 16) i) (ldb (byte 8 8) i) (ldb (byte 8 0) i)))
                                        (out (copy-seq u)))
                                   (loop repeat (1- iterations)
                                         do (setf u (hmac-sha1 password u))
                                            (map-into out #'logxor out u))
                                   out)))
            0 length)))

(defun prf-sha1 (key label data bits)
  (let ((length (ceiling bits 8)))
    (subseq (apply #'octets (loop for i from 0 below (ceiling length 20)
                                  collect (hmac-sha1 key label 0 data i)))
            0 length)))

(defun random-octets (n)
  (let ((out (make-array n :element-type '(unsigned-byte 8)))
        (machdep (sb-sys:find-foreign-symbol-address "__machdep")))
    (if machdep
        (sb-sys:with-pinned-objects (out)
          (unless (= n (sb-alien:alien-funcall
                        (sb-alien:sap-alien (sb-sys:int-sap machdep)
                                            (function sb-alien:unsigned-long sb-alien:long sb-alien:unsigned-long sb-alien:unsigned-long))
                        16 (sb-sys:sap-int (sb-sys:vector-sap out)) n))
            (error "the processor gave no random numbers")))
        (with-open-file (s "/dev/urandom" :element-type '(unsigned-byte 8))
          (read-sequence out s)))
    out))
