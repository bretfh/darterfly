(defpackage #:finch/ca
  (:use #:cl)
  (:export #:render-error #:decode-commit #:encode-commit #:commit-stream #:*commands*))
(in-package #:finch/ca)

(define-condition render-error (error)
  ((text :initarg :text :reader render-error-text))
  (:report (lambda (c s) (write-string (render-error-text c) s))))

(defun bad (control &rest args)
  (error 'render-error :text (apply #'format nil control args)))

(defparameter *commands*
  '((1 :delete-object :id :int32)
    (2 :set-object :id :int32 :object :int32)
    (3 :update-layer :id)
    (5 :remove-all-animations :id)
    (7 :set-layer-id :id)
    (9 :set-colorspace :colorspace)
    (11 :order-relative-above :int32)
    (12 :order-relative-below :int32)
    (13 :order-level :int32)
    (17 17 :id :int32)
    (18 :flush-image-queue :int32 :int32)
    (26 :add-input-time :double)
    (27 27 :int8)
    (28 :add-remote-input-mach-time :int64)
    (29 29 :double)
    (30 30 :int64)
    (31 31 :int8)
    (32 32 :int32 :int8)
    (33 33 :int32)
    (34 :set-unobscured-roi :double :double :double :double)
    (35 35 :int32)
    (36 36 :int8)
    (37 37 :port)
    (38 38 :int64)
    (40 :set-glitch-request :double)))

(defun command-by-code (code) (assoc code *commands*))

(defun command-by-name (name)
  (or (find name *commands* :key #'second :test #'eql) (bad "no command ~s" name)))

(defstruct (reader (:constructor reader (octets))) octets (at 0))

(defun take (r count)
  (let ((end (+ (reader-at r) count)))
    (when (> end (length (reader-octets r)))
      (bad "commit runs out at ~d" (reader-at r)))
    (prog1 (subseq (reader-octets r) (reader-at r) end)
      (setf (reader-at r) end))))

(defun take-le (r count)
  (let ((o (take r count)))
    (loop :with n := 0
          :for i :from (1- count) :downto 0
          :do (setf n (logior (ash n 8) (aref o i)))
          :finally (return n))))

(defun signed (bits n) (if (logbitp (1- bits) n) (- n (ash 1 bits)) n))

(defun writer () (make-array 0 :element-type '(unsigned-byte 8) :adjustable t :fill-pointer 0))

(defun put-le (w count n) (dotimes (i count) (vector-push-extend (ldb (byte 8 (* 8 i)) n) w)))

(defun put-octets (w octets) (loop :for o :across octets :do (vector-push-extend o w)))

(defun take-double (r)
  (let ((bits (take-le r 8)))
    (sb-kernel:make-double-float (signed 32 (ash bits -32)) (ldb (byte 32 0) bits))))

(defun put-double (w x)
  (let ((d (coerce x 'double-float)))
    (put-le w 4 (sb-kernel:double-float-low-bits d))
    (put-le w 4 (sb-kernel:double-float-high-bits d))))

(defun take-single (r) (sb-kernel:make-single-float (signed 32 (take-le r 4))))

(defun put-single (w x) (put-le w 4 (sb-kernel:single-float-bits (coerce x 'single-float))))

(defgeneric encode-operand (type value w))
(defgeneric decode-operand (type r))

(defmacro define-operand (type (value w r) encode decode)
  `(progn
     (defmethod encode-operand ((type (eql ,type)) ,value ,w) ,encode)
     (defmethod decode-operand ((type (eql ,type)) ,r) ,decode)))

(define-operand :int8 (v w r) (put-le w 1 v) (take-le r 1))
(define-operand :int32 (v w r) (put-le w 4 v) (take-le r 4))
(define-operand :int64 (v w r) (put-le w 8 v) (take-le r 8))
(define-operand :id (v w r) (put-le w 8 v) (take-le r 8))
(define-operand :double (v w r) (put-double w v) (take-double r))
(define-operand :port (v w r) (declare (ignore v w)) (progn r :port))

(define-operand :colorspace (v w r)
  (destructuring-bind (&optional (code 0) index) v
    (put-le w 1 code)
    (case code
      ((0 3))
      (1 (put-le w 1 index))
      (t (bad "colorspace code ~d not encoded yet" code))))
  (let ((code (take-le r 1)))
    (case code
      (0 nil)
      (1 (list 1 (take-le r 1)))
      (3 (list 3))
      (t (bad "colorspace code ~d not decoded yet" code)))))

(defgeneric encode-object (tag object w))
(defgeneric decode-object (tag r))

(defmethod decode-object (tag r)
  (declare (ignore r))
  (bad "object type #x~2,'0x not decoded yet" tag))

(define-operand :object (v w r)
  (if (null v)
      (put-le w 1 0)
      (let ((tag (getf v :type)))
        (put-le w 1 tag)
        (encode-object tag v w)))
  (let ((tag (take-le r 1)))
    (if (zerop tag) nil (decode-object tag r))))

(defconstant +layer+ #x1e)

(defparameter *layer-block*
  '((:background-color :single 4) (:at-10 :int32) (:opacity :int8) (:shadow-opacity :int8)
    (:contents-scale :int8) (:rasterization-scale :int8) (:flags-a :int64) (:flags-b :int64)
    (:position :double 2) (:bounds :double 4)))

(defun take-field (r kind)
  (ecase kind
    (:single (take-single r))
    (:double (take-double r))
    (:int8 (take-le r 1))
    (:int32 (take-le r 4))
    (:int64 (take-le r 8))))

(defun put-field (w kind v)
  (ecase kind
    (:single (put-single w v))
    (:double (put-double w v))
    (:int8 (put-le w 1 v))
    (:int32 (put-le w 4 v))
    (:int64 (put-le w 8 v))))

(defun take-sublayers (r)
  (ecase (take-le r 1)
    (0 nil)
    (1 (let ((flags (take-le r 4))
             (count (take-le r 4)))
         (unless (logbitp 0 flags) (bad "sublayers sent as objects, not ids"))
         (coerce (loop :repeat count :collect (take-le r 8)) 'vector)))))

(defun put-sublayers (w ids)
  (if (null ids)
      (put-le w 1 0)
      (progn (put-le w 1 1) (put-le w 4 1) (put-le w 4 (length ids))
             (map nil (lambda (id) (put-le w 8 id)) ids))))

(defmethod decode-object ((tag (eql +layer+)) r)
  (let ((layer (list :type tag :flags (take-le r 4))))
    (loop :for (name kind count) :in *layer-block*
          :do (setf layer (append layer
                                  (list name (if count
                                                 (coerce (loop :repeat count :collect (take-field r kind)) 'vector)
                                                 (take-field r kind))))))
    (setf layer (append layer (list :contents (decode-operand :object r)
                                    :sublayers (take-sublayers r)
                                    :mask (take-le r 8)
                                    :name (decode-operand :object r))))
    (unless (zerop (take-le r 1)) (bad "layer extension block not decoded yet"))
    layer))

(defmethod encode-object ((tag (eql +layer+)) layer w)
  (put-le w 4 (getf layer :flags))
  (loop :for (name kind count) :in *layer-block*
        :for v := (getf layer name)
        :do (if count (map nil (lambda (x) (put-field w kind x)) v) (put-field w kind v)))
  (encode-operand :object (getf layer :contents) w)
  (put-sublayers w (getf layer :sublayers))
  (put-le w 8 (getf layer :mask))
  (encode-operand :object (getf layer :name) w)
  (put-le w 1 0))

(defun decode-commit (octets)
  (let* ((r (reader (coerce octets '(simple-array (unsigned-byte 8) (*)))))
         (flags (take-le r 4)))
    (unless (= 1 (logand flags #b1001))
      (bad "commit flags #x~x: only 64-bit streams without sanity words are read" flags))
    (list :flags flags :context (take-le r 4) :time (take-double r)
          :commands (loop :for code := (take-le r 1)
                          :until (zerop code)
                          :collect (destructuring-bind (name &rest types)
                                       (or (rest (command-by-code code)) (bad "invalid command ~d" code))
                                     (cons name (mapcar (lambda (type) (decode-operand type r)) types)))))))

(defun encode-commit (commit)
  (let ((w (writer)))
    (put-le w 4 (getf commit :flags))
    (put-le w 4 (getf commit :context))
    (put-double w (getf commit :time))
    (dolist (command (getf commit :commands))
      (destructuring-bind (code name &rest types) (command-by-name (first command))
        (declare (ignore name))
        (put-le w 1 code)
        (mapc (lambda (type value) (encode-operand type value w)) types (rest command))))
    (put-le w 1 0)
    (coerce w '(simple-array (unsigned-byte 8) (*)))))

(defun commit-stream (message)
  (let* ((complex (logbitp 31 (logior (aref message 0) (ash (aref message 1) 8)
                                      (ash (aref message 2) 16) (ash (aref message 3) 24))))
         (r (reader (coerce message '(simple-array (unsigned-byte 8) (*))))))
    (take r 24)
    (let ((count (take-le r 4)))
      (when complex
        (dotimes (i count)
          (take r 8)
          (let ((type (ldb (byte 8 24) (take-le r 4))))
            (case type
              (0)
              ((1 2) (take r 4))
              (t (bad "descriptor type ~d" type)))))))
    (subseq (reader-octets r) (reader-at r))))
