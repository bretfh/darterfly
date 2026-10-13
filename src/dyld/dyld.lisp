(defpackage #:finch/dyld
  (:use #:cl)
  (:export
   #:open-cache #:dyld-error
   #:cache #:cache-files #:cache-images #:cache-uuid #:cache-platform
   #:cache-os-version #:cache-architecture
   #:cache-file #:file-path #:file-suffix #:file-uuid #:file-mappings
   #:mapping #:mapping-address #:mapping-size #:mapping-file-offset
   #:mapping-max-prot #:mapping-init-prot
   #:cache-image #:image-path #:image-address
   #:find-image #:address-file #:cache-read #:image-macho #:extract-image))
(in-package #:finch/dyld)

(define-condition dyld-error (error)
  ((what :initarg :what :reader what))
  (:report (lambda (c s) (format s "not a dyld shared cache: ~a" (what c)))))

(defun bad (fmt &rest args)
  (error 'dyld-error :what (apply #'format nil fmt args)))

(defun read-at (path offset count)
  (with-open-file (in path :element-type '(unsigned-byte 8))
    (file-position in offset)
    (let* ((v (make-array count :element-type '(unsigned-byte 8)))
           (n (read-sequence v in)))
      (when (< n count) (bad "~a ends before ~d" path (+ offset count)))
      v)))

(defun le (o at count)
  (loop :with n := 0
        :for i :from (+ at count -1) :downto at
        :do (setf n (logior (ash n 8) (aref o i)))
        :finally (return n)))

(defun cstring (o at)
  (map 'string #'code-char (subseq o at (or (position 0 o :start at) (length o)))))

(defun uuid-string (o at)
  (format nil "~{~2,'0X~2,'0X~2,'0X~2,'0X-~2,'0X~2,'0X-~2,'0X~2,'0X-~2,'0X~2,'0X-~2,'0X~2,'0X~2,'0X~2,'0X~2,'0X~2,'0X~}"
          (coerce (subseq o at (+ at 16)) 'list)))

(defparameter +header+
  '((:mapping-offset 16 4) (:mapping-count 20 4)
    (:code-signature-offset 40 8) (:code-signature-size 48 8)
    (:uuid 88 16) (:cache-type 104 8) (:platform 216 4)
    (:shared-region-start 224 8) (:shared-region-size 232 8)
    (:os-version 364 4) (:sub-cache-array-offset 392 4) (:sub-cache-array-count 396 4)
    (:symbol-file-uuid 400 16) (:images-offset 448 4) (:images-count 452 4)
    (:cache-sub-type 456 4)))

(defclass mapping ()
  ((address :initarg :address :reader mapping-address)
   (size :initarg :size :reader mapping-size)
   (file-offset :initarg :file-offset :reader mapping-file-offset)
   (max-prot :initarg :max-prot :reader mapping-max-prot)
   (init-prot :initarg :init-prot :reader mapping-init-prot)))

(defmethod print-object ((m mapping) stream)
  (print-unreadable-object (m stream :type t)
    (format stream "#x~x +#x~x" (mapping-address m) (mapping-size m))))

(defclass cache-file ()
  ((path :initarg :path :reader file-path)
   (suffix :initarg :suffix :reader file-suffix)
   (header :initarg :header :reader header)
   (mappings :initarg :mappings :reader file-mappings)))

(defmethod print-object ((f cache-file) stream)
  (print-unreadable-object (f stream :type t)
    (format stream "~a" (file-namestring (file-path f)))))

(defun field (file name)
  (destructuring-bind (offset width) (rest (assoc name +header+))
    (let ((o (header file)))
      (cond ((>= offset (le o 16 4)) nil)
            ((= width 16) (uuid-string o offset))
            (t (le o offset width))))))

(defun file-uuid (file)
  (field file :uuid))

(defclass cache-image ()
  ((path :initarg :path :reader image-path)
   (address :initarg :address :reader image-address)))

(defmethod print-object ((i cache-image) stream)
  (print-unreadable-object (i stream :type t)
    (format stream "~a #x~x" (image-path i) (image-address i))))

(defclass cache ()
  ((files :initarg :files :reader cache-files)
   (images :initarg :images :reader cache-images)
   (by-path :initform (make-hash-table :test 'equal) :reader by-path)))

(defun main-file (cache)
  (first (cache-files cache)))

(defun cache-uuid (cache) (file-uuid (main-file cache)))
(defun cache-platform (cache) (field (main-file cache) :platform))

(defun cache-os-version (cache)
  (let ((v (field (main-file cache) :os-version)))
    (and v (format nil "~d.~d.~d" (ldb (byte 16 16) v) (ldb (byte 8 8) v) (ldb (byte 8 0) v)))))

(defun cache-architecture (cache)
  (string-trim " " (subseq (cstring (header (main-file cache)) 0) 7)))

(defun read-file (path suffix)
  (let* ((start (read-at path 0 16)))
    (unless (string= "dyld_v1" (map 'string #'code-char (subseq start 0 7)))
      (bad "~a has no dyld_v1 magic" path))
    (let* ((size (le (read-at path 16 4) 0 4))
           (header (read-at path 0 size))
           (count (le header 20 4))
           (table (read-at path size (* 32 count))))
      (make-instance 'cache-file
        :path path :suffix suffix :header header
        :mappings (loop :for i :below count
                        :for at := (* 32 i)
                        :collect (make-instance 'mapping
                                   :address (le table at 8)
                                   :size (le table (+ at 8) 8)
                                   :file-offset (le table (+ at 16) 8)
                                   :max-prot (le table (+ at 24) 4)
                                   :init-prot (le table (+ at 28) 4)))))))

(defun sub-caches (main)
  (let ((offset (field main :sub-cache-array-offset))
        (count (or (field main :sub-cache-array-count) 0))
        (wide (field main :cache-sub-type)))
    (when (plusp count)
      (let* ((stride (if wide 56 24))
             (table (read-at (file-path main) offset (* stride count))))
        (loop :for i :below count
              :for at := (* stride i)
              :collect (cons (uuid-string table at)
                             (if wide
                                 (cstring (subseq table (+ at 24) (+ at 56)) 0)
                                 (format nil ".~2,'0d" (1+ i)))))))))

(defun open-cache (path)
  (let* ((path (uiop:native-namestring path))
         (main (read-file path ""))
         (files (cons main
                      (loop :for (uuid . suffix) :in (sub-caches main)
                            :collect (let ((f (read-file (concatenate 'string path suffix) suffix)))
                                       (unless (equal uuid (file-uuid f))
                                         (bad "~a~a is ~a, the main cache names ~a"
                                              path suffix (file-uuid f) uuid))
                                       f))))
         (count (or (field main :images-count) 0))
         (table (read-at path (field main :images-offset) (* 32 count)))
         (offsets (loop :for i :below count :collect (le table (+ (* 32 i) 24) 4)))
         (low (reduce #'min offsets :initial-value most-positive-fixnum))
         (high (reduce #'max offsets :initial-value 0))
         (strings (and offsets (read-at path low (+ (- high low) 4096))))
         (cache (make-instance 'cache
                  :files files
                  :images (loop :for i :below count
                                :for offset :in offsets
                                :collect (make-instance 'cache-image
                                           :address (le table (* 32 i) 8)
                                           :path (cstring strings (- offset low)))))))
    (dolist (image (cache-images cache) cache)
      (setf (gethash (image-path image) (by-path cache)) image))))

(defun find-image (cache path)
  (gethash path (by-path cache)))

(defun address-file (cache address)
  (dolist (file (cache-files cache) (bad "#x~x is in no mapping" address))
    (dolist (m (file-mappings file))
      (when (<= (mapping-address m) address (+ (mapping-address m) (mapping-size m) -1))
        (return-from address-file
          (values file (+ (mapping-file-offset m) (- address (mapping-address m)))))))))

(defun cache-read (cache address count)
  (multiple-value-bind (file offset) (address-file cache address)
    (read-at (file-path file) offset count)))

(defun image-macho (cache image)
  (let* ((address (image-address (if (stringp image) (find-image cache image) image)))
         (head (cache-read cache address 32)))
    (finch/macho:read-macho (cache-read cache address (+ 32 (le head 20 4))))))
