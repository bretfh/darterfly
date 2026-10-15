(defpackage #:finch/fat
  (:use #:cl)
  (:local-nicknames (#:vfs #:finch/vfs) (#:iokit #:finch/iokit))
  (:export #:newfs #:file-store #:open-volume #:mount #:mount-esp #:volume-label
           #:lookup #:entries #:read-file #:write-file #:make-entry #:remove-entry #:resolve
           #:entry-name #:entry-directory-p #:entry-size))
(in-package #:finch/fat)

(defconstant +sector+ 512)
(defconstant +eoc+ #x0FFFFFFF)
(defconstant +attr-directory+ #x10)
(defconstant +attr-archive+ #x20)
(defconstant +attr-lfn+ #x0F)

(defun u (v at n) (loop :for i :below n :sum (ash (aref v (+ at i)) (* 8 i))))

(defun (setf u) (value v at n)
  (dotimes (i n value) (setf (aref v (+ at i)) (ldb (byte 8 (* 8 i)) value))))

(defun octets (n) (make-array n :element-type '(unsigned-byte 8) :initial-element 0))

(defun file-store (path)
  (values (lambda (at length)
            (with-open-file (s path :element-type '(unsigned-byte 8))
              (let ((v (octets length)))
                (file-position s at)
                (read-sequence v s)
                v)))
          (lambda (at v)
            (with-open-file (s path :direction :output :element-type '(unsigned-byte 8) :if-exists :overwrite)
              (file-position s at)
              (write-sequence v s)))))

(defstruct (volume (:constructor %make-volume))
  read write label
  cluster-sectors reserved fats fat-sectors root-cluster clusters
  fat (dirty nil) (hint 2) (chains (make-hash-table)) free
  (lock (sb-thread:make-mutex :name "fat")))

(defun cluster-bytes (v) (* +sector+ (volume-cluster-sectors v)))

(defun cluster-offset (v n)
  (* +sector+ (+ (volume-reserved v) (* (volume-fats v) (volume-fat-sectors v))
                 (* (- n 2) (volume-cluster-sectors v)))))

(defun open-volume (read write)
  (let* ((boot (funcall read 0 +sector+))
         (fat-sectors (u boot 36 4))
         (reserved (u boot 14 2))
         (cluster-sectors (aref boot 13))
         (fats (aref boot 16))
         (fat (funcall read (* reserved +sector+) (* fat-sectors +sector+)))
         (v (%make-volume :read read :write write
                          :label (string-right-trim " " (map 'string #'code-char (subseq boot 71 82)))
                          :cluster-sectors cluster-sectors :reserved reserved :fats fats
                          :fat-sectors fat-sectors :root-cluster (u boot 44 4)
                          :clusters (floor (- (u boot 32 4) reserved (* fats fat-sectors)) cluster-sectors)
                          :fat fat)))
    (setf (volume-free v) (loop :for n :from 2 :below (+ 2 (volume-clusters v)) :count (zerop (next-cluster v n))))
    (unless (and (= (u boot 11 2) +sector+) (= (u boot 510 2) #xAA55) (zerop (u boot 22 2)))
      (error "not a FAT32 volume"))
    v))

(defun next-cluster (v n) (logand (u (volume-fat v) (* 4 n) 4) #x0FFFFFFF))

(defun (setf next-cluster) (value v n)
  (pushnew (floor (* 4 n) +sector+) (volume-dirty v))
  (setf (u (volume-fat v) (* 4 n) 4) value))

(defun chain (v n)
  (loop :while (and (>= n 2) (< n #x0FFFFFF8))
        :collect n
        :do (setf n (next-cluster v n))))

(defun free-cluster (v)
  (let ((last (+ 2 (volume-clusters v))))
    (loop :repeat (volume-clusters v)
          :for n := (volume-hint v) :then (if (>= (1+ n) last) 2 (1+ n))
          :when (zerop (next-cluster v n))
            :do (setf (volume-hint v) (1+ n))
                (return-from free-cluster n))
    (vfs:fail :enospc)))

(defun allocate (v &optional after (zero t))
  (let ((n (free-cluster v)))
    (setf (next-cluster v n) +eoc+)
    (decf (volume-free v))
    (when after (setf (next-cluster v after) n))
    (when zero (funcall (volume-write v) (cluster-offset v n) (octets (cluster-bytes v))))
    n))

(defun file-chain (v n)
  (if (< n 2)
      (make-array 0 :adjustable t :fill-pointer t)
      (or (gethash n (volume-chains v))
          (setf (gethash n (volume-chains v))
                (let ((c (chain v n))) (make-array (length c) :adjustable t :fill-pointer t :initial-contents c))))))

(defun release (v n)
  (clrhash (volume-chains v))
  (dolist (c (chain v n))
    (incf (volume-free v))
    (setf (next-cluster v c) 0))
  (setf (volume-hint v) (min (volume-hint v) (max 2 n))))

(defun sync-fat (v)
  (when (volume-dirty v)
    (let ((info (funcall (volume-read v) +sector+ +sector+)))
      (setf (u info 488 4) (volume-free v) (u info 492 4) (volume-hint v))
      (funcall (volume-write v) +sector+ info)))
  (dolist (s (shiftf (volume-dirty v) nil))
    (let ((data (subseq (volume-fat v) (* s +sector+) (* (1+ s) +sector+))))
      (dotimes (copy (volume-fats v))
        (funcall (volume-write v)
                 (* +sector+ (+ (volume-reserved v) (* copy (volume-fat-sectors v)) s))
                 data)))))

(defmacro with-volume ((v) &body body)
  `(sb-thread:with-recursive-lock ((volume-lock ,v))
     (multiple-value-prog1 (progn ,@body) (sync-fat ,v))))

(defun read-chain (v n)
  (let* ((clusters (chain v n))
         (size (cluster-bytes v))
         (out (octets (* size (length clusters)))))
    (loop :for c :in clusters :for at :from 0 :by size
          :do (replace out (funcall (volume-read v) (cluster-offset v c) size) :start1 at))
    out))

(defstruct (entry (:constructor %entry)) name short attr cluster size slot slots)

(defun entry-directory-p (e) (logtest (entry-attr e) +attr-directory+))

(defun short-text (d at)
  (flet ((part (from to lower)
           (let ((s (string-right-trim " " (map 'string #'code-char (subseq d from to)))))
             (if lower (string-downcase s) s))))
    (let ((base (part at (+ at 8) (logtest (aref d (+ at 12)) #x08)))
          (ext (part (+ at 8) (+ at 11) (logtest (aref d (+ at 12)) #x10))))
      (if (string= ext "") base (format nil "~a.~a" base ext)))))

(defun lfn-chars (d at)
  (loop :for (from count) :in '((1 5) (14 6) (28 2))
        :nconc (loop :for i :below count
                     :for c := (u d (+ at from (* 2 i)) 2)
                     :until (or (zerop c) (= c #xFFFF))
                     :collect (code-char c))))

(defun parse-directory (d)
  (let ((long nil) (first nil) (out nil))
    (loop :for at :from 0 :below (length d) :by 32
          :for slot :from 0
          :for b := (aref d at)
          :do (cond ((zerop b) (return))
                    ((= b #xE5) (setf long nil first nil))
                    ((= (aref d (+ at 11)) #x08) (setf long nil first nil))
                    ((= (aref d (+ at 11)) +attr-lfn+)
                     (when (logtest b #x40) (setf long nil first slot))
                     (push (lfn-chars d at) long))
                    (t
                     (let ((short (short-text d at)))
                       (unless (member short '("." "..") :test #'string=)
                         (push (%entry :name (if long (coerce (apply #'append long) 'string) short)
                                           :short (subseq d at (+ at 11))
                                           :attr (aref d (+ at 11))
                                           :cluster (logior (ash (u d (+ at 20) 2) 16) (u d (+ at 26) 2))
                                           :size (u d (+ at 28) 4)
                                           :slot slot
                                           :slots (if long (- slot first -1) 1))
                               out)))
                     (setf long nil first nil))))
    (nreverse out)))

(defun entries (v cluster) (parse-directory (read-chain v cluster)))

(defun lookup (v cluster name)
  (find name (entries v cluster) :key #'entry-name :test #'string-equal))

(defun resolve (v path)
  (let ((cluster (volume-root-cluster v)) (entry nil))
    (dolist (part (remove "" (uiop:split-string path :separator "/") :test #'string=) entry)
      (setf entry (lookup v cluster part))
      (unless entry (return nil))
      (setf cluster (entry-cluster entry)))))

(defun write-slot (v cluster slot octets)
  (let* ((size (cluster-bytes v))
         (clusters (chain v cluster))
         (at (* 32 slot)))
    (multiple-value-bind (index offset) (floor at size)
      (funcall (volume-write v) (+ (cluster-offset v (nth index clusters)) offset) octets))))

(defun update-entry (v dir entry &key (cluster (entry-cluster entry)) (size (entry-size entry)))
  (let ((d (read-chain v dir)) (at (* 32 (entry-slot entry))))
    (setf (u d (+ at 20) 2) (ldb (byte 16 16) cluster)
          (u d (+ at 26) 2) (ldb (byte 16 0) cluster)
          (u d (+ at 28) 4) size
          (entry-cluster entry) cluster
          (entry-size entry) size)
    (write-slot v dir (entry-slot entry) (subseq d at (+ at 32)))))

(defun dos-time ()
  (multiple-value-bind (s m h day month year) (decode-universal-time (get-universal-time) 0)
    (values (logior (ash h 11) (ash m 5) (floor s 2))
            (logior (ash (- year 1980) 9) (ash month 5) day))))

(defun short-name (name taken)
  (let* ((dot (position #\. name :from-end t))
         (clean (lambda (s n) (subseq (remove-if-not (lambda (c) (or (alphanumericp c) (find c "_-~"))) (string-upcase s))
                                      0 (min n (count-if (lambda (c) (or (alphanumericp c) (find c "_-~"))) s)))))
         (base (funcall clean (if (and dot (plusp dot)) (subseq name 0 dot) name) 8))
         (ext (if (and dot (plusp dot)) (funcall clean (subseq name (1+ dot)) 3) "")))
    (flet ((pack (b) (map '(vector (unsigned-byte 8)) #'char-code
                          (concatenate 'string (format nil "~8a" b) (format nil "~3a" ext)))))
      (if (and (string= (string-upcase name) (if (string= ext "") base (format nil "~a.~a" base ext)))
               (string= name (string-upcase name))
               (not (find (pack base) taken :test #'equalp)))
          (values (pack base) nil)
          (loop :for i :from 1
                :for tail := (format nil "~~~d" i)
                :for short := (pack (concatenate 'string (subseq base 0 (min (length base) (- 8 (length tail)))) tail))
                :unless (find short taken :test #'equalp)
                  :return (values short t))))))

(defun checksum (short)
  (let ((sum 0))
    (loop :for b :across short :do (setf sum (logand #xFF (+ (ash (logand sum 1) 7) (ash sum -1) b))))
    sum))

(defun lfn-slots (name short)
  (let* ((chars (map 'list #'char-code name))
         (n (ceiling (1+ (length chars)) 13))
         (padded (append chars (list 0) (make-list (- (* 13 n) (length chars) 1) :initial-element #xFFFF)))
         (sum (checksum short)))
    (loop :for i :from n :downto 1
          :collect (let ((s (octets 32))
                         (part (subseq padded (* 13 (1- i)) (* 13 i))))
                     (setf (aref s 0) (if (= i n) (logior #x40 i) i)
                           (aref s 11) +attr-lfn+
                           (aref s 13) sum)
                     (loop :for c :in part :for k :from 0
                           :for at := (cond ((< k 5) (+ 1 (* 2 k))) ((< k 11) (+ 14 (* 2 (- k 5)))) (t (+ 28 (* 2 (- k 11)))))
                           :do (setf (u s at 2) c))
                     s))))

(defun short-slot (short attr cluster size)
  (let ((s (octets 32)))
    (replace s short)
    (setf (aref s 11) attr)
    (multiple-value-bind (time date) (dos-time)
      (setf (u s 14 2) time (u s 16 2) date (u s 18 2) date (u s 22 2) time (u s 24 2) date))
    (setf (u s 20 2) (ldb (byte 16 16) cluster) (u s 26 2) (ldb (byte 16 0) cluster) (u s 28 4) size)
    s))

(defun free-run (d count)
  (let ((run 0))
    (loop :for at :from 0 :below (length d) :by 32
          :for slot :from 0
          :do (if (member (aref d at) '(0 #xE5))
                  (when (= (incf run) count) (return-from free-run (- slot count -1)))
                  (setf run 0)))
    nil))

(defun add-slots (v dir slots)
  (loop
    (let* ((d (read-chain v dir))
           (at (free-run d (length slots))))
      (when at
        (loop :for s :in slots :for i :from at :do (write-slot v dir i s))
        (return at))
      (allocate v (car (last (chain v dir)))))))

(defun make-entry (v dir name &key directory)
  (when (lookup v dir name) (vfs:fail :eexist))
  (multiple-value-bind (short long) (short-name name (mapcar #'entry-short (entries v dir)))
    (let* ((cluster (if directory (allocate v) 0))
           (slots (append (and long (lfn-slots name short))
                          (list (short-slot short (if directory +attr-directory+ +attr-archive+) cluster 0)))))
      (when directory
        (let ((dots (octets (* 64))))
          (replace dots (short-slot (map 'vector #'char-code ".          ") +attr-directory+ cluster 0))
          (replace dots (short-slot (map 'vector #'char-code "..         ") +attr-directory+
                                    (if (= dir (volume-root-cluster v)) 0 dir) 0)
                   :start1 32)
          (funcall (volume-write v) (cluster-offset v cluster) dots)))
      (add-slots v dir slots)
      (lookup v dir name))))

(defun remove-entry (v dir entry &key (free t))
  (let ((first (- (entry-slot entry) (entry-slots entry) -1)))
    (loop :for slot :from first :to (entry-slot entry)
          :do (write-slot v dir slot (let ((s (octets 1))) (setf (aref s 0) #xE5) s))))
  (when (and free (>= (entry-cluster entry) 2))
    (release v (entry-cluster entry))))

(defun runs (clusters)
  (let ((out nil))
    (map nil (lambda (c)
               (if (and out (= c (+ (car (first out)) (cdr (first out)))))
                   (incf (cdr (first out)))
                   (push (cons c 1) out)))
         clusters)
    (nreverse out)))

(defun map-runs (v clusters start end function)
  (let ((size (cluster-bytes v)) (from 0))
    (loop :for (c . n) :in (runs clusters)
          :for to := (+ from (* n size))
          :do (when (and (< start to) (> end from))
                (let ((a (max start from)) (b (min end to)))
                  (funcall function (+ (cluster-offset v c) (- a from)) a b)))
              (setf from to)
          :while (< from end))))

(defun read-file (v entry start end)
  (let* ((end (min end (entry-size entry)))
         (out (octets (max 0 (- end start)))))
    (when (< start end)
      (map-runs v (file-chain v (entry-cluster entry)) start end
                (lambda (at a b) (replace out (funcall (volume-read v) at (- b a)) :start1 (- a start)))))
    out))

(defun ensure-clusters (v dir entry count)
  (let* ((clusters (file-chain v (entry-cluster entry)))
         (have (length clusters)))
    (cond ((> count have)
           (let ((last (and (plusp have) (aref clusters (1- have)))))
             (loop :repeat (- count have)
                   :do (setf last (allocate v last nil))
                       (vector-push-extend last clusters))
             (when (zerop have)
               (setf (gethash (aref clusters 0) (volume-chains v)) clusters)
               (update-entry v dir entry :cluster (aref clusters 0)))))
          ((< count have)
           (if (zerop count)
               (progn (release v (entry-cluster entry)) (update-entry v dir entry :cluster 0))
               (let ((keep (aref clusters (1- count))))
                 (release v (next-cluster v keep))
                 (setf (next-cluster v keep) +eoc+)))))
    (file-chain v (entry-cluster entry))))

(defun write-file (v dir entry offset octets)
  (let* ((end (+ offset (length octets)))
         (size (cluster-bytes v))
         (clusters (ensure-clusters v dir entry (max (ceiling (max end (entry-size entry)) size)
                                                     (length (file-chain v (entry-cluster entry)))))))
    (map-runs v clusters offset end
              (lambda (at a b) (funcall (volume-write v) at (subseq octets (- a offset) (- b offset)))))
    (when (> end (entry-size entry)) (update-entry v dir entry :size end))
    (length octets)))

(defun truncate-file (v dir entry size)
  (ensure-clusters v dir entry (ceiling size (cluster-bytes v)))
  (update-entry v dir entry :size size))

(defun format-volume (read write size label)
  (let* ((sectors (floor size +sector+))
         (reserved 32)
         (cluster-sectors (or (find-if (lambda (spc)
                                         (> (floor (- sectors reserved) spc) 66000))
                                       '(8 4 2 1))
                              (error "~d bytes is too small for FAT32" size)))
         (fat-sectors (loop :for f := 1 :then next
                            :for clusters := (floor (- sectors reserved (* 2 f)) cluster-sectors)
                            :for next := (ceiling (* 4 (+ clusters 2)) +sector+)
                            :until (<= next f)
                            :finally (return f)))
         (boot (octets +sector+))
         (info (octets +sector+)))
    (replace boot #(#xEB #x58 #x90))
    (replace boot (map 'vector #'char-code "FINCH   ") :start1 3)
    (setf (u boot 11 2) +sector+ (aref boot 13) cluster-sectors (u boot 14 2) reserved (aref boot 16) 2
          (aref boot 21) #xF8 (u boot 24 2) 32 (u boot 26 2) 64 (u boot 32 4) sectors (u boot 36 4) fat-sectors
          (u boot 44 4) 2 (u boot 48 2) 1 (u boot 50 2) 6 (aref boot 64) #x80 (aref boot 66) #x29
          (u boot 67 4) (random #xFFFFFFFF) (u boot 510 2) #xAA55)
    (replace boot (map 'vector #'char-code (format nil "~11a" (string-upcase label))) :start1 71)
    (replace boot (map 'vector #'char-code "FAT32   ") :start1 82)
    (setf (u info 0 4) #x41615252 (u info 484 4) #x61417272 (u info 488 4) #xFFFFFFFF
          (u info 492 4) #xFFFFFFFF (u info 508 4) #xAA550000)
    (funcall write (* +sector+ (1- sectors)) (octets +sector+))
    (dolist (at '(0 6)) (funcall write (* +sector+ at) boot) (funcall write (* +sector+ (1+ at)) info))
    (let ((fat (octets (* fat-sectors +sector+))))
      (setf (u fat 0 4) #x0FFFFFF8 (u fat 4 4) #x0FFFFFFF (u fat 8 4) +eoc+)
      (dotimes (copy 2) (funcall write (* +sector+ (+ reserved (* copy fat-sectors))) fat)))
    (let ((root (octets (* cluster-sectors +sector+))))
      (replace root (short-slot (map 'vector #'char-code (format nil "~11a" (string-upcase label))) #x08 0 0))
      (funcall write (* +sector+ (+ reserved (* 2 fat-sectors))) root))
    (let ((v (open-volume read write)))
      (push 0 (volume-dirty v))
      (sync-fat v)
      v)))
