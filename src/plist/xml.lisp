(in-package #:finch/plist)

(defparameter +base64+
  "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")

(defparameter +blank+ '(#\Space #\Tab #\Newline #\Return))

(defun base64 (text)
  (let ((bits 0) (n 0) (out (make-array 0 :element-type '(unsigned-byte 8)
                                          :adjustable t :fill-pointer 0)))
    (loop :for c :across text
          :for v := (position c +base64+)
          :when v
            :do (setf bits (logior (ash bits 6) v))
                (incf n 6)
                (when (>= n 8)
                  (decf n 8)
                  (vector-push-extend (ldb (byte 8 n) bits) out)
                  (setf bits (ldb (byte n 0) bits))))
    (coerce out '(simple-array (unsigned-byte 8) (*)))))

(defun iso-8601 (text)
  (flet ((field (start end) (parse-integer text :start start :end end)))
    (unless (and (>= (length text) 19) (char= (char text 4) #\-) (char= (char text 10) #\T))
      (bad "date ~s" text))
    (make-date (coerce (- (encode-universal-time (field 17 19) (field 14 16) (field 11 13)
                                                 (field 8 10) (field 5 7) (field 0 4) 0)
                          +epoch+)
                       'double-float))))

(defun real-number (text)
  (let ((s (string-downcase (string-trim +blank+ text))))
    (cond ((string= s "nan") (sb-kernel:make-double-float #x7ff80000 0))
          ((member s '("inf" "+inf" "infinity" "+infinity") :test #'string=)
           sb-ext:double-float-positive-infinity)
          ((member s '("-inf" "-infinity") :test #'string=)
           sb-ext:double-float-negative-infinity)
          (t (let ((v (let ((*read-eval* nil)
                            (*read-default-float-format* 'double-float))
                        (read-from-string s))))
               (unless (realp v) (bad "real ~s" text))
               (coerce v 'double-float))))))

(defun elements (node)
  (remove-if-not #'plump:element-p (coerce (plump:children node) 'list)))

(defun value (node)
  (let ((text (plump:text node)))
    (cond
      ((string= (plump:tag-name node) "dict")
       (let ((h (make-hash-table :test 'equal)))
         (loop :for (k v) :on (elements node) :by #'cddr
               :do (unless (and v (string= (plump:tag-name k) "key"))
                     (bad "dict out of key/value order"))
                   (setf (gethash (plump:text k) h) (value v)))
         h))
      ((string= (plump:tag-name node) "array")
       (map 'vector #'value (elements node)))
      ((string= (plump:tag-name node) "string") text)
      ((string= (plump:tag-name node) "integer")
       (let ((s (string-trim +blank+ text)))
         (if (and (> (length s) 2) (string-equal "0x" s :end2 2))
             (parse-integer s :start 2 :radix 16)
             (parse-integer s))))
      ((string= (plump:tag-name node) "real") (real-number text))
      ((string= (plump:tag-name node) "true") t)
      ((string= (plump:tag-name node) "false") nil)
      ((string= (plump:tag-name node) "date") (iso-8601 text))
      ((string= (plump:tag-name node) "data") (base64 text))
      (t (bad "element <~a>" (plump:tag-name node))))))

(defun read-xml-plist (source)
  (let* ((o (file-octets source))
         (root (plump:parse (sb-ext:octets-to-string o :external-format :utf-8)))
         (plist (find "plist" (elements root) :key #'plump:tag-name :test #'string=))
         (top (and plist (elements plist))))
    (unless top (bad "no <plist> element"))
    (value (first top))))

(defun base64-text (octets)
  (with-output-to-string (s)
    (loop :for i :from 0 :below (length octets) :by 3
          :for n := (min 3 (- (length octets) i))
          :for bits := (loop :for j :below 3
                             :for b := (if (< j n) (aref octets (+ i j)) 0)
                             :sum (ash b (* 8 (- 2 j))))
          :do (loop :for j :below 4
                    :do (write-char (if (<= j n)
                                        (char +base64+ (ldb (byte 6 (* 6 (- 3 j))) bits))
                                        #\=)
                                    s)))))

(defun escaped (text s)
  (loop :for c :across text
        :do (case c
              (#\& (write-string "&amp;" s))
              (#\< (write-string "&lt;" s))
              (#\> (write-string "&gt;" s))
              (t (write-char c s)))))

(defun real-text (x)
  (let ((x (coerce x 'double-float)))
    (cond ((sb-ext:float-nan-p x) "nan")
          ((sb-ext:float-infinity-p x) (if (plusp x) "inf" "-inf"))
          ((= x (ffloor x)) (format nil "~,1f" x))
          (t (let ((*read-default-float-format* 'double-float))
               (prin1-to-string x))))))

(defun iso-text (date)
  (multiple-value-bind (sec min hour day month year)
      (decode-universal-time (date-universal-time date) 0)
    (format nil "~4,'0d-~2,'0d-~2,'0dT~2,'0d:~2,'0d:~2,'0dZ" year month day hour min sec)))

(defun emit (value depth s)
  (flet ((line (fmt &rest args)
           (loop :repeat depth :do (write-char #\Tab s))
           (apply #'format s fmt args)
           (terpri s))
         (leaf (tag text)
           (loop :repeat depth :do (write-char #\Tab s))
           (format s "<~a>" tag)
           (escaped text s)
           (format s "</~a>~%" tag)))
    (typecase value
      (hash-table
       (if (zerop (hash-table-count value))
           (line "<dict/>")
           (progn
             (line "<dict>")
             (maphash (lambda (k v)
                        (incf depth)
                        (leaf "key" k)
                        (emit v depth s)
                        (decf depth))
                      value)
             (line "</dict>"))))
      (string (leaf "string" value))
      ((eql t) (line "<true/>"))
      (null (line "<false/>"))
      (integer (line "<integer>~d</integer>" value))
      (real (line "<real>~a</real>" (real-text value)))
      (date (line "<date>~a</date>" (iso-text value)))
      ((vector (unsigned-byte 8)) (line "<data>~a</data>" (base64-text value)))
      (vector
       (if (zerop (length value))
           (line "<array/>")
           (progn
             (line "<array>")
             (loop :for v :across value :do (emit v (1+ depth) s))
             (line "</array>"))))
      (t (bad "no XML form for ~s" value)))))

(defun write-plist (value destination)
  (if (streamp destination)
      (progn
        (format destination "<?xml version=\"1.0\" encoding=\"UTF-8\"?>~%~
<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">~%~
<plist version=\"1.0\">~%")
        (emit value 0 destination)
        (format destination "</plist>~%")
        nil)
      (with-open-file (s destination :direction :output :if-exists :supersede
                                     :external-format :utf-8)
        (write-plist value s))))
