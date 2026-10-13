(defpackage #:finch/plist
  (:use #:cl)
  (:export
   #:read-plist #:read-xml-plist #:read-binary-plist #:plist-error
   #:date #:make-date #:date-absolute-time #:date-universal-time
   #:uid #:make-uid #:uid-value #:+null+))
(in-package #:finch/plist)

(define-condition plist-error (error)
  ((what :initarg :what :reader what))
  (:report (lambda (c s) (format s "not a property list: ~a" (what c)))))

(defun bad (fmt &rest args)
  (error 'plist-error :what (apply #'format nil fmt args)))

(defconstant +epoch+ (encode-universal-time 0 0 0 1 1 2001 0))
(defparameter +null+ :null)

(defstruct (date (:constructor make-date (absolute-time)))
  (absolute-time 0d0 :type double-float))

(defun date-universal-time (date)
  (+ +epoch+ (floor (date-absolute-time date))))

(defstruct (uid (:constructor make-uid (value)))
  (value 0 :type unsigned-byte))

(defun file-octets (source)
  (etypecase source
    ((vector (unsigned-byte 8)) (coerce source '(simple-array (unsigned-byte 8) (*))))
    ((or pathname string)
     (with-open-file (in source :element-type '(unsigned-byte 8))
       (let ((v (make-array (file-length in) :element-type '(unsigned-byte 8))))
         (read-sequence v in)
         v)))))

(defun starts-with (octets prefix)
  (and (>= (length octets) (length prefix))
       (loop :for c :across prefix :for i :from 0
             :always (= (aref octets i) (char-code c)))))

(defun read-plist (source)
  (let ((octets (file-octets source)))
    (if (starts-with octets "bplist00")
        (read-binary-plist octets)
        (read-xml-plist octets))))
