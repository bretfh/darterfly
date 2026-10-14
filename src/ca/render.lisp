(defpackage #:finch/ca
  (:use #:cl)
  (:export #:render-error #:decode-commit #:encode-commit #:commit-stream #:*commands*
           #:layer #:make-layer #:layer-id #:layer-position #:layer-bounds #:layer-frame
           #:layer-background-color #:layer-opacity #:layer-masks-to-bounds #:layer-sublayers
           #:context #:context-create #:context-id #:context-layer #:commit #:+masks-to-bounds+
           #:layer-contents #:image #:next-event #:context-events #:window-create #:transaction-commit #:main-display-bounds))
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
    (6 :remove-animation :id :cfobject)
    (7 :set-layer-id :id)
    (8 :set-client-info :cfobject)
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

(defun put-octets (w octets)
  (let* ((start (fill-pointer w))
         (end (+ start (length octets))))
    (when (> end (array-dimension w 0))
      (setf w (adjust-array w (max end (* 2 (array-dimension w 0))))))
    (setf (fill-pointer w) end)
    (replace w octets :start1 start)
    w))

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
      ((2 4) (encode-operand :cfobject index w))
      (t (bad "colorspace code ~d not encoded yet" code))))
  (let ((code (take-le r 1)))
    (case code
      (0 nil)
      (1 (list 1 (take-le r 1)))
      ((2 4) (list code (decode-operand :cfobject r)))
      (3 (list 3))
      (t (bad "colorspace code ~d not decoded yet" code)))))

(defun cf-tag (value)
  (cond ((eq value :null) 0)
        ((stringp value) 2)
        ((and (consp value) (eq (first value) :number)) 3)
        ((and (consp value) (eq (first value) :data)) 5)
        ((and (consp value) (eq (first value) :array)) 6)
        ((and (consp value) (eq (first value) :dictionary)) 7)
        ((and (consp value) (eq (first value) :boolean)) 1)
        (t (bad "no cf encoding for ~s" value))))

(define-operand :cfobject (v w r)
  (let ((tag (cf-tag v)))
    (put-le w 1 tag)
    (ecase tag
      (0)
      (1 (put-le w 1 (if (second v) 1 0)))
      (2 (let ((octets (sb-ext:string-to-octets v :external-format :utf-8)))
           (put-le w 1 1) (put-le w 8 (1+ (length octets))) (put-octets w octets) (put-le w 1 0)))
      (3 (put-le w 1 (second v)) (put-le w 8 (ldb (byte 64 0) (third v))))
      (5 (put-le w 8 (length (second v))) (put-octets w (second v)))
      ((6 7) (put-le w 8 (length (rest v)))
       (dolist (item (rest v))
         (if (= tag 7)
             (progn (encode-operand :cfobject (car item) w) (encode-operand :cfobject (cdr item) w))
             (encode-operand :cfobject item w))))))
  (let ((tag (take-le r 1)))
    (case tag
      (0 :null)
      (1 (list :boolean (plusp (take-le r 1))))
      (2 (let ((encoding (take-le r 1)) (n (take-le r 8)))
           (unless (= encoding 1) (bad "cf string encoding ~d not read yet" encoding))
           (sb-ext:octets-to-string (subseq (take r n) 0 (1- n)) :external-format :utf-8)))
      (3 (let ((kind (take-le r 1))) (list :number kind (signed 64 (take-le r 8)))))
      (5 (list :data (take r (take-le r 8))))
      (6 (cons :array (loop :repeat (take-le r 8) :collect (decode-operand :cfobject r))))
      (7 (cons :dictionary (loop :repeat (take-le r 8)
                                 :collect (cons (decode-operand :cfobject r) (decode-operand :cfobject r)))))
      (t (bad "cf object tag ~d not read yet" tag)))))

(defgeneric encode-object (tag object w))
(defgeneric decode-object (tag r))

(defmethod decode-object (tag r)
  (declare (ignore r))
  (bad "object type #x~2,'0x not decoded yet" tag))

(defconstant +cached+ #xfe)
(defconstant +reference+ #xff)

(define-operand :object (v w r)
  (cond ((null v) (put-le w 1 0))
        ((eq (getf v :type) :cached)
         (put-le w 1 +cached+) (put-le w 8 (getf v :id)) (put-le w 4 (getf v :key))
         (encode-operand :object (getf v :object) w))
        ((eq (getf v :type) :reference)
         (put-le w 1 +reference+) (put-le w 8 (getf v :id)) (put-le w 4 (getf v :key)))
        (t (let ((tag (getf v :type)))
             (put-le w 1 tag)
             (encode-object tag v w))))
  (let ((tag (take-le r 1)))
    (cond ((zerop tag) nil)
          ((= tag +cached+)
           (list :type :cached :id (take-le r 8) :key (take-le r 4) :object (decode-operand :object r)))
          ((= tag +reference+)
           (list :type :reference :id (take-le r 8) :key (take-le r 4)))
          (t (decode-object tag r)))))

(define-operand :data (v w r)
  (progn (put-le w 8 (length v)) (put-octets w v))
  (take r (take-le r 8)))

(defconstant +image+ #x17)
(defconstant +shmem+ #x34)

(defun take-shape (r)
  (let ((n (signed 32 (take-le r 4))))
    (cond ((= n -2) (list :bounds (loop :repeat 4 :collect (signed 32 (take-le r 4)))))
          ((member n '(0 -1)) n)
          (t (list :spans n (take r (* 4 (- n 3))))))))

(defun put-shape (w shape)
  (cond ((integerp shape) (put-le w 4 (ldb (byte 32 0) shape)))
        ((eq (first shape) :bounds)
         (put-le w 4 (ldb (byte 32 0) -2))
         (dolist (v (second shape)) (put-le w 4 (ldb (byte 32 0) v))))
        (t (put-le w 4 (second shape)) (put-octets w (third shape)))))

(defun take-texture (r flags)
  (list :colorspace (decode-operand :colorspace r)
        :texture-a (take-le r 4)
        :texture-b (loop :repeat 4 :collect (take-le r 2))
        :shape (take-shape r)
        :texture-c (take-le r 4)
        :texture-d (take-le r 4)
        :texture-e (and (logtest flags #x1000) (take r 20))))

(defun put-texture (w object)
  (encode-operand :colorspace (getf object :colorspace) w)
  (put-le w 4 (getf object :texture-a))
  (dolist (v (getf object :texture-b)) (put-le w 2 v))
  (put-shape w (getf object :shape))
  (put-le w 4 (getf object :texture-c))
  (put-le w 4 (getf object :texture-d))
  (when (getf object :texture-e) (put-octets w (getf object :texture-e))))

(defmethod decode-object ((tag (eql +image+)) r)
  (let* ((flags (take-le r 4))
         (format (take-le r 1))
         (levels (take-le r 1))
         (width (take-le r 4))
         (height (take-le r 4))
         (rowbytes (loop :repeat levels :collect (take-le r 8)))
         (shmem (plusp (take-le r 1)))
         (pixels (if shmem (decode-operand :object r) (decode-operand :data r))))
    (append (list :type tag :flags flags :format format :width width :height height :rowbytes rowbytes
                  (if shmem :shmem :pixels) pixels)
            (take-texture r flags))))

(defmethod encode-object ((tag (eql +image+)) image w)
  (put-le w 4 (getf image :flags))
  (put-le w 1 (getf image :format))
  (put-le w 1 (length (getf image :rowbytes)))
  (put-le w 4 (getf image :width))
  (put-le w 4 (getf image :height))
  (dolist (rowbytes (getf image :rowbytes)) (put-le w 8 rowbytes))
  (if (getf image :shmem)
      (progn (put-le w 1 1) (encode-operand :object (getf image :shmem) w))
      (progn (put-le w 1 0) (encode-operand :data (getf image :pixels) w)))
  (put-texture w image))

(defmethod decode-object ((tag (eql +shmem+)) r)
  (let ((flags (take-le r 4)))
    (if (zerop (logand flags 3))
        (list :type tag :flags flags :data (decode-operand :data r))
        (list :type tag :flags flags :size (take-le r 8) :offset (take-le r 8) :port :port))))

(defmethod encode-object ((tag (eql +shmem+)) shmem w)
  (put-le w 4 (getf shmem :flags))
  (if (zerop (logand (getf shmem :flags) 3))
      (encode-operand :data (getf shmem :data) w)
      (progn (put-le w 8 (getf shmem :size)) (put-le w 8 (getf shmem :offset)))))

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

(defparameter *layer-ext*
  '(:object :object :object :object :object :object :object :object :object :object :object :object
    :array :array :object :object :object :array :object :object :array
    (:bytes 16) (:bytes 16) :int64 :int64 (:bytes 20) (:bytes 8)
    :int32 :int32 :int32 :int32 (:bytes 20) :int32 :int32 :int32 :int32 :int32 (:bytes 20)
    :int32 :int32 :int32 :int32 :int32 (:bytes 20) :int32 :int64 :object :object :int8))

(defun take-array (r)
  (ecase (take-le r 1)
    (0 nil)
    (1 (let* ((flags (take-le r 4)) (count (take-le r 4)))
         (list :array flags
               (loop :repeat count :collect (if (logbitp 0 flags) (take-le r 8) (decode-operand :object r))))))))

(defun put-array (w array)
  (if (null array)
      (put-le w 1 0)
      (destructuring-bind (flags items) (rest array)
        (put-le w 1 1) (put-le w 4 flags) (put-le w 4 (length items))
        (dolist (item items)
          (if (logbitp 0 flags) (put-le w 8 item) (encode-operand :object item w))))))

(defun take-ext (r kind)
  (cond ((eq kind :object) (decode-operand :object r))
        ((eq kind :array) (take-array r))
        ((eq kind :atom) (take-atom r))
        ((consp kind) (take r (second kind)))
        (t (take-field r kind))))

(defun put-ext (w kind value)
  (cond ((eq kind :object) (encode-operand :object value w))
        ((eq kind :array) (put-array w value))
        ((eq kind :atom) (put-atom w value))
        ((consp kind) (put-octets w value))
        (t (put-field w kind value))))

(defconstant +vector+ #x3e)

(defmethod decode-object ((tag (eql +vector+)) r)
  (let ((n (take-le r 4)))
    (list :type tag :values (coerce (loop :repeat n :collect (take-double r)) 'vector))))

(defmethod encode-object ((tag (eql +vector+)) object w)
  (put-le w 4 (length (getf object :values)))
  (map nil (lambda (x) (put-double w x)) (getf object :values)))

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
    (when (plusp (take-le r 1))
      (setf layer (append layer (list :ext (loop :for kind :in *layer-ext* :collect (take-ext r kind))))))
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
  (let ((ext (getf layer :ext)))
    (put-le w 1 (if ext 1 0))
    (mapc (lambda (kind value) (put-ext w kind value)) *layer-ext* ext)))

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

(defconstant +string+ #x36)

(defmethod decode-object ((tag (eql +string+)) r)
  (let ((n (take-le r 4)))
    (list :type tag :string (sb-ext:octets-to-string (take r n) :external-format :utf-8))))

(defmethod encode-object ((tag (eql +string+)) object w)
  (let ((octets (sb-ext:string-to-octets (getf object :string) :external-format :utf-8)))
    (put-le w 4 (length octets))
    (put-octets w octets)))

(defmacro define-field-object (tag &rest kinds)
  `(progn
     (defmethod decode-object ((tag (eql ,tag)) r)
       (list :type tag :fields (loop :for kind :in ',kinds :collect (take-ext r kind))))
     (defmethod encode-object ((tag (eql ,tag)) object w)
       (mapc (lambda (kind value) (put-ext w kind value)) ',kinds (getf object :fields)))))

(define-field-object #x03 :int32 :int64 :object :int32 :int32 :int32 :int32 (:bytes 32) :int32 (:bytes 32) :int8)

(defun take-atom (r)
  (let ((b (take-le r 1)))
    (case b
      (#xfe (list :u16 (take-le r 2)))
      (#xff (list :name (decode-operand :data r)))
      (t b))))

(defun put-atom (w atom)
  (cond ((integerp atom) (put-le w 1 atom))
        ((eq (first atom) :u16) (put-le w 1 #xfe) (put-le w 2 (second atom)))
        (t (put-le w 1 #xff) (encode-operand :data (second atom) w))))

(define-field-object #x1d :atom :object)

(defconstant +filter+ #x12)

(defmethod decode-object ((tag (eql +filter+)) r)
  (let ((flags (take-le r 4)))
    (if (logbitp 8 flags)
        (list :type tag :flags flags :shared (take-atom r))
        (let ((kind (take-le r 1)))
          (ecase kind
            (1 (list :type tag :flags flags :kind kind :name (take-atom r)
                     :string (decode-operand :object r) :values (take-array r)))
            (0 (list :type tag :flags flags :kind kind :cfobject (decode-operand :cfobject r))))))))

(defmethod encode-object ((tag (eql +filter+)) filter w)
  (put-le w 4 (getf filter :flags))
  (if (logbitp 8 (getf filter :flags))
      (put-atom w (getf filter :shared))
      (progn
        (put-le w 1 (getf filter :kind))
        (if (= 1 (getf filter :kind))
            (progn (put-atom w (getf filter :name))
                   (encode-operand :object (getf filter :string) w)
                   (put-array w (getf filter :values)))
            (encode-operand :cfobject (getf filter :cfobject) w)))))
