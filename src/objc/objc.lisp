(defpackage #:finch/objc
  (:use #:cl)
  (:shadow #:class-name)
  (:export
   #:image-objc #:objc-error
   #:objc-image #:objc-image-path #:objc-image-classes #:objc-image-categories
   #:objc-image-protocols
   #:objc-class #:class-name #:class-superclass #:class-address #:class-instance-size
   #:class-instance-methods #:class-class-methods #:class-ivars #:class-properties
   #:class-protocols #:class-swift-p
   #:objc-method #:method-selector #:method-types #:method-imp
   #:ivar #:ivar-name #:ivar-type #:ivar-offset #:ivar-size
   #:property #:property-name #:property-attributes
   #:category #:category-name #:category-class
   #:category-instance-methods #:category-class-methods #:category-protocols
   #:category-properties
   #:protocol #:protocol-name #:protocol-protocols #:protocol-instance-methods
   #:protocol-class-methods #:protocol-optional-instance-methods
   #:protocol-optional-class-methods #:protocol-properties))
(in-package #:finch/objc)

(define-condition objc-error (error)
  ((what :initarg :what :reader what))
  (:report (lambda (c s) (format s "objc: ~a" (what c)))))

(defconstant +chunk+ 65536)
(defconstant +fast-data-mask+ #x00007ffffffffff8)
(defconstant +relative+ #x80000000)
(defconstant +selector-offsets+ #x40000000)
(defconstant +type-offsets+ #x20000000)

(defclass memory ()
  ((cache :initarg :cache :reader cache)
   (chunks :initform (make-hash-table) :reader chunks)
   (mask :initarg :mask :reader mask)
   (add :initarg :add :reader add)
   (selectors :initarg :selectors :reader selectors)
   (types :initarg :types :reader types)))

(defun le (o at count)
  (loop :with n := 0
        :for i :from (+ at count -1) :downto at
        :do (setf n (logior (ash n 8) (aref o i)))
        :finally (return n)))

(defun signed (n bits)
  (if (logbitp (1- bits) n) (- n (ash 1 bits)) n))

(defun chunk (memory address)
  (let ((base (* +chunk+ (floor address +chunk+))))
    (values (or (gethash base (chunks memory))
                (setf (gethash base (chunks memory))
                      (finch/dyld:cache-read (cache memory) base +chunk+)))
            (- address base))))

(defun peek (memory address count)
  (multiple-value-bind (o at) (chunk memory address)
    (if (<= (+ at count) +chunk+)
        (le o at count)
        (le (finch/dyld:cache-read (cache memory) address count) 0 count))))

(defun pointer (memory address)
  (let ((value (logandc2 (peek memory address 8) (mask memory))))
    (if (zerop value) 0 (+ value (add memory)))))

(defun text (memory address)
  (if (zerop address)
      nil
      (with-output-to-string (s)
        (loop :for a :from address
              :for b := (multiple-value-bind (o at) (chunk memory a) (aref o at))
              :until (zerop b)
              :do (write-char (code-char b) s)))))

(defun utf-8 (string)
  (handler-case
      (sb-ext:octets-to-string (map '(vector (unsigned-byte 8)) #'char-code string)
                               :external-format :utf-8)
    (error () string)))

(defun open-memory (cache)
  (let* ((main (first (finch/dyld:cache-files cache)))
         (start (finch/dyld::field main :shared-region-start))
         (objc-opts (le (finch/dyld::header main) 464 8))
         (opts (finch/dyld:cache-read cache (+ start objc-opts) 72))
         (selector-base (le opts 48 8))
         (slide (first (finch/dyld::slides cache)))
         (info (finch/dyld::slide-info slide)))
    (make-instance 'memory :cache cache :mask (le info 24 8) :add (le info 32 8)
                           :selectors (+ start selector-base)
                           :types (+ start selector-base (le opts 56 8)))))

(defun lists (memory address)
  (cond ((zerop address) nil)
        ((logbitp 0 address)
         (let* ((base (1- address))
                (size (peek memory base 4)))
           (loop :for i :below (peek memory (+ base 4) 4)
                 :for at := (+ base 8 (* i size))
                 :collect (+ at (signed (ash (peek memory at 8) -16) 48)))))
        (t (list address))))

(defclass objc-method ()
  ((selector :initarg :selector :reader method-selector)
   (types :initarg :types :reader method-types)
   (imp :initarg :imp :reader method-imp)))

(defmethod print-object ((m objc-method) stream)
  (print-unreadable-object (m stream :type t)
    (format stream "~a #x~x" (method-selector m) (method-imp m))))

(defclass ivar ()
  ((name :initarg :name :reader ivar-name)
   (type :initarg :type :reader ivar-type)
   (offset :initarg :offset :reader ivar-offset)
   (size :initarg :size :reader ivar-size)))

(defclass property ()
  ((name :initarg :name :reader property-name)
   (attributes :initarg :attributes :reader property-attributes)))

(defclass objc-class ()
  ((name :initarg :name :reader class-name)
   (superclass :initarg :superclass :reader class-superclass)
   (address :initarg :address :reader class-address)
   (instance-size :initarg :instance-size :reader class-instance-size)
   (instance-methods :initarg :instance-methods :reader class-instance-methods)
   (class-methods :initarg :class-methods :reader class-class-methods)
   (ivars :initarg :ivars :reader class-ivars)
   (properties :initarg :properties :reader class-properties)
   (protocols :initarg :protocols :reader class-protocols)
   (swift :initarg :swift :reader class-swift-p)))

(defmethod print-object ((c objc-class) stream)
  (print-unreadable-object (c stream :type t)
    (format stream "~a : ~a" (class-name c) (class-superclass c))))

(defclass category ()
  ((name :initarg :name :reader category-name)
   (class :initarg :class :reader category-class)
   (instance-methods :initarg :instance-methods :reader category-instance-methods)
   (class-methods :initarg :class-methods :reader category-class-methods)
   (protocols :initarg :protocols :reader category-protocols)
   (properties :initarg :properties :reader category-properties)))

(defmethod print-object ((c category) stream)
  (print-unreadable-object (c stream :type t)
    (format stream "~a (~a)" (category-class c) (category-name c))))

(defclass protocol ()
  ((name :initarg :name :reader protocol-name)
   (protocols :initarg :protocols :reader protocol-protocols)
   (instance-methods :initarg :instance-methods :reader protocol-instance-methods)
   (class-methods :initarg :class-methods :reader protocol-class-methods)
   (optional-instance-methods :initarg :optional-instance-methods
                              :reader protocol-optional-instance-methods)
   (optional-class-methods :initarg :optional-class-methods
                           :reader protocol-optional-class-methods)
   (properties :initarg :properties :reader protocol-properties)))

(defmethod print-object ((p protocol) stream)
  (print-unreadable-object (p stream :type t)
    (format stream "~a" (protocol-name p))))

(defclass objc-image ()
  ((path :initarg :path :reader objc-image-path)
   (classes :initarg :classes :reader objc-image-classes)
   (categories :initarg :categories :reader objc-image-categories)
   (protocols :initarg :protocols :reader objc-image-protocols)))

(defmethod print-object ((i objc-image) stream)
  (print-unreadable-object (i stream :type t)
    (format stream "~a: ~d classes, ~d categories, ~d protocols" (objc-image-path i)
            (length (objc-image-classes i)) (length (objc-image-categories i))
            (length (objc-image-protocols i)))))

(defun methods (memory address)
  (loop :for list :in (lists memory address)
        :nconc (list-methods memory list)))

(defun list-methods (memory list)
  (progn
    (let* ((flags (peek memory list 4))
           (count (peek memory (+ list 4) 4))
           (size (logand flags #xfffc)))
      (loop :for i :below count
            :for at := (+ list 8 (* i size))
            :collect (if (logtest flags +relative+)
                         (let ((name (signed (peek memory at 4) 32))
                               (types (signed (peek memory (+ at 4) 4) 32))
                               (imp (signed (peek memory (+ at 8) 4) 32)))
                           (make-instance 'objc-method
                             :selector (text memory (if (logtest flags +selector-offsets+)
                                                        (+ (selectors memory) name)
                                                        (pointer memory (+ at name))))
                             :types (text memory (if (logtest flags +type-offsets+)
                                                     (+ (types memory) (ldb (byte 32 0) types))
                                                     (+ at 4 types)))
                             :imp (if (zerop imp) 0 (+ at 8 imp))))
                         (make-instance 'objc-method
                           :selector (text memory (pointer memory at))
                           :types (text memory (pointer memory (+ at 8)))
                           :imp (pointer memory (+ at 16))))))))

(defun ivars (memory list)
  (unless (zerop list)
    (let ((size (peek memory list 4))
          (count (peek memory (+ list 4) 4)))
      (loop :for i :below count
            :for at := (+ list 8 (* i size))
            :for offset := (pointer memory at)
            :collect (make-instance 'ivar
                       :name (text memory (pointer memory (+ at 8)))
                       :type (text memory (pointer memory (+ at 16)))
                       :offset (if (zerop offset) nil (peek memory offset 4))
                       :size (peek memory (+ at 28) 4))))))

(defun properties (memory address)
  (loop :for list :in (lists memory address)
        :nconc (list-properties memory list)))

(defun list-properties (memory list)
  (progn
    (let ((size (peek memory list 4))
          (count (peek memory (+ list 4) 4)))
      (loop :for i :below count
            :for at := (+ list 8 (* i size))
            :collect (make-instance 'property
                       :name (utf-8 (text memory (pointer memory at)))
                       :attributes (text memory (pointer memory (+ at 8))))))))

(defun protocol-names (memory address)
  (loop :for list :in (lists memory address)
        :nconc (list-protocol-names memory list)))

(defun list-protocol-names (memory list)
  (progn
    (loop :for i :below (peek memory list 8)
          :collect (text memory (pointer memory (+ 8 (pointer memory (+ list 8 (* 8 i)))))))))

(defun class-ro (memory class)
  (logand (pointer memory (+ class 32)) +fast-data-mask+))

(defun name-of (memory class)
  (unless (zerop class)
    (utf-8 (text memory (pointer memory (+ (class-ro memory class) 24))))))

(defun read-class (memory class)
  (let* ((ro (class-ro memory class))
         (meta (pointer memory class))
         (meta-ro (and (plusp meta) (class-ro memory meta))))
    (make-instance 'objc-class
      :name (name-of memory class)
      :superclass (name-of memory (pointer memory (+ class 8)))
      :address class
      :instance-size (peek memory (+ ro 8) 4)
      :instance-methods (methods memory (pointer memory (+ ro 32)))
      :class-methods (and meta-ro (methods memory (pointer memory (+ meta-ro 32))))
      :ivars (ivars memory (pointer memory (+ ro 48)))
      :properties (properties memory (pointer memory (+ ro 64)))
      :protocols (protocol-names memory (pointer memory (+ ro 40)))
      :swift (logtest 3 (peek memory (+ class 32) 8)))))

(defun read-category (memory at)
  (let ((class (pointer memory (+ at 8))))
    (make-instance 'category
      :name (text memory (pointer memory at))
      :class (and (plusp class) (name-of memory class))
      :instance-methods (methods memory (pointer memory (+ at 16)))
      :class-methods (methods memory (pointer memory (+ at 24)))
      :protocols (protocol-names memory (pointer memory (+ at 32)))
      :properties (properties memory (pointer memory (+ at 40))))))

(defun read-protocol (memory at)
  (make-instance 'protocol
    :name (text memory (pointer memory (+ at 8)))
    :protocols (protocol-names memory (pointer memory (+ at 16)))
    :instance-methods (methods memory (pointer memory (+ at 24)))
    :class-methods (methods memory (pointer memory (+ at 32)))
    :optional-instance-methods (methods memory (pointer memory (+ at 40)))
    :optional-class-methods (methods memory (pointer memory (+ at 48)))
    :properties (properties memory (pointer memory (+ at 56)))))

(defun section-pointers (memory image name)
  (let ((s (find name (finch/macho:sections image) :key #'finch/macho:section-name
                                                   :test #'string=)))
    (when s
      (loop :for at :from (finch/macho:section-addr s)
              :below (+ (finch/macho:section-addr s) (finch/macho:section-size s)) :by 8
            :collect (pointer memory at)))))

(defvar *memory* nil)

(defun image-objc (cache path)
  (let* ((memory (if (and *memory* (eq cache (cache *memory*)))
                     *memory*
                     (setf *memory* (open-memory cache))))
         (image (finch/dyld:image-macho cache path)))
    (make-instance 'objc-image
      :path path
      :classes (mapcar (lambda (c) (read-class memory c))
                       (section-pointers memory image "__objc_classlist"))
      :categories (mapcar (lambda (c) (read-category memory c))
                          (section-pointers memory image "__objc_catlist"))
      :protocols (mapcar (lambda (p) (read-protocol memory p))
                         (section-pointers memory image "__objc_protolist")))))
