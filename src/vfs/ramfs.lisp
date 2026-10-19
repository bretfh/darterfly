(in-package #:darterfly/vfs)

(defvar *next-ino* 2)

(defun now ()
  (multiple-value-bind (sec usec) (sb-ext:get-time-of-day)
    (+ (* sec 1000000000) (* usec 1000))))

(defclass ram-node (vnode)
  ((mode :initarg :mode :accessor node-mode)
   (uid :initform 0 :accessor node-uid)
   (gid :initform 0 :accessor node-gid)
   (mtime :initform (now) :accessor node-mtime)
   (children :initform nil :accessor node-children)
   (data :initform (make-array 0 :element-type '(unsigned-byte 8)) :accessor node-data)
   (size :initform 0 :accessor node-size)
   (external :initform nil :accessor node-external)
   (shared-capacity :initform 0 :accessor node-shared-capacity)
   (target :initform nil :accessor node-target)))

(defmethod initialize-instance :after ((n ram-node) &key)
  (setf (vnode-id n) (prog1 *next-ino* (incf *next-ino*))))

(defun make-ram-node (type mode) (make-instance 'ram-node :type type :mode mode))

(defun add-child (dir name node)
  (push (cons name node) (node-children dir))
  (setf (node-mtime dir) (now))
  node)

(defun drop-child (dir name)
  (setf (node-children dir) (remove name (node-children dir) :key #'car :test #'string=)
        (node-mtime dir) (now)))

(defmethod vnop-lookup ((dir ram-node) name) (cdr (assoc name (node-children dir) :test #'string=)))
(defmethod vnop-readdir ((dir ram-node)) (copy-list (node-children dir)))

(defun own-data (n need)
  (when (or (node-external n) (> need (length (node-data n))))
    (let ((data (make-array (max 256 (* 2 need)) :element-type '(unsigned-byte 8))))
      (if (node-external n)
          (sb-sys:with-pinned-objects (data)
            (sb-kernel:system-area-ub8-copy (node-external n) 0 (sb-sys:vector-sap data) 0 (node-size n)))
          (replace data (node-data n) :end2 (node-size n)))
      (setf (node-data n) data (node-external n) nil))))

(defmethod vnop-read ((n ram-node) offset count)
  (let* ((end (min (node-size n) (+ offset count)))
         (out (make-array (max 0 (- end offset)) :element-type '(unsigned-byte 8))))
    (when (plusp (length out))
      (if (node-external n)
          (sb-sys:with-pinned-objects (out)
            (sb-kernel:system-area-ub8-copy (node-external n) offset (sb-sys:vector-sap out) 0 (length out)))
          (replace out (node-data n) :start2 offset)))
    out))

(defvar *shared-ram-nodes* nil)

(defconstant +shared-file-capacity+ (* 64 1024 1024))

(defun shared-zero (n start end)
  (when (> end start)
    (sb-alien:alien-funcall
     (sb-alien:extern-alien "memset"
       (function sb-alien:system-area-pointer sb-alien:system-area-pointer
                 sb-alien:int sb-alien:unsigned-long))
     (sb-sys:sap+ (node-external n) start) 0 (- end start))))

(defun promote-shared-data (n)
  ;; Reserve a stable address, with physical pages allocated on demand by the
  ;; normal VM. Mapped processes retain frames independently of this owner.
  (unless (and (typep n 'ram-node) (eq (vnode-type n) :vreg))
    (fail :eopnotsupp))
  (when (> (node-size n) +shared-file-capacity+) (fail :efbig))
  (when (zerop (node-shared-capacity n))
    (let ((sap (sb-posix:mmap (sb-sys:int-sap 0) +shared-file-capacity+
                             (logior sb-posix:prot-read sb-posix:prot-write)
                             (logior sb-posix:map-private sb-posix:map-anon)
                             -1 0)))
      (if (node-external n)
          (sb-kernel:system-area-ub8-copy (node-external n) 0 sap 0 (node-size n))
          (let ((data (node-data n)))
            (sb-sys:with-pinned-objects (data)
              (sb-kernel:system-area-ub8-copy (sb-sys:vector-sap data) 0
                                             sap 0 (node-size n)))))
      (setf (node-external n) sap
            (node-data n) (make-array 0 :element-type '(unsigned-byte 8))
            (node-shared-capacity n) +shared-file-capacity+)
      (setf *shared-ram-nodes*
            (delete-if-not #'sb-ext:weak-pointer-value *shared-ram-nodes*))
      (push (sb-ext:make-weak-pointer n) *shared-ram-nodes*)
      (sb-ext:finalize n (lambda () (sb-posix:munmap sap +shared-file-capacity+))
                       :dont-save t)))
  (node-external n))

(defun save-shared-ram-data ()
  ;; Core files retain file bytes, never an address into the previous VM.
  ;; Keep old frames alive until this saving process exits: outstanding views
  ;; may still refer to them. Live cross-world mappings are not checkpointed.
  (dolist (weak *shared-ram-nodes*)
    (let ((node (sb-ext:weak-pointer-value weak)))
      (when node
        (let ((data (vnop-read node 0 (node-size node))))
          (sb-ext:cancel-finalization node)
          (setf (node-data node) data (node-external node) nil
                (node-shared-capacity node) 0)))))
  (setf *shared-ram-nodes* nil))

(pushnew 'save-shared-ram-data sb-ext:*save-hooks*)

(defmethod vnop-write ((n ram-node) offset octets)
  (let ((end (+ offset (length octets))))
    (if (plusp (node-shared-capacity n))
        (progn
          (when (> end (node-shared-capacity n)) (fail :efbig))
          (shared-zero n (node-size n) offset)
          (let ((data (coerce octets '(simple-array (unsigned-byte 8) (*)))))
            (sb-sys:with-pinned-objects (data)
              (sb-kernel:system-area-ub8-copy (sb-sys:vector-sap data) 0
                                             (node-external n) offset (length data)))))
        (progn
          (own-data n (max end (node-size n)))
          (when (> offset (node-size n))
            (fill (node-data n) 0 :start (node-size n) :end offset))
          (replace (node-data n) octets :start1 offset)))
    (setf (node-size n) (max end (node-size n)) (node-mtime n) (now))
    (length octets)))

(defmethod vnop-truncate ((n ram-node) size)
  (unless (eq (vnode-type n) :vreg) (fail :einval))
  (if (plusp (node-shared-capacity n))
      (progn
        ;; Shrinking would require revocation and SIGBUS for existing views.
        (when (< size (node-size n)) (fail :ebusy))
        (when (> size (node-shared-capacity n)) (fail :efbig))
        (shared-zero n (node-size n) size))
      (progn
        (own-data n (max size (node-size n)))
        (when (> size (node-size n))
          (fill (node-data n) 0 :start (node-size n) :end size))))
  (setf (node-size n) size))

(defmethod vnop-getattr ((n ram-node))
  (make-vattr :mode (logior (ecase (vnode-type n) (:vdir #o040000) (:vreg #o100000) (:vlnk #o120000) (:vsock #o140000)) (node-mode n))
              :uid (node-uid n) :gid (node-gid n)
              :size (case (vnode-type n) (:vreg (node-size n)) (:vlnk (length (sb-ext:string-to-octets (node-target n) :external-format :utf-8))) (t 0))
              :nlink (if (eq (vnode-type n) :vdir) 2 1)
              :mtime (node-mtime n)))

(defmethod vnop-readlink ((n ram-node))
  (unless (eq (vnode-type n) :vlnk) (fail :einval))
  (node-target n))

(defmethod vnop-create ((dir ram-node) name mode) (add-child dir name (make-ram-node :vreg mode)))
(defmethod vnop-mksocket ((dir ram-node) name mode)
  (add-child dir name (make-ram-node :vsock mode)))

(defmethod vnop-mkdir ((dir ram-node) name mode) (add-child dir name (make-ram-node :vdir mode)))

(defmethod vnop-symlink ((dir ram-node) name target)
  (let ((n (make-ram-node :vlnk #o755)))
    (setf (node-target n) target)
    (add-child dir name n)))

(defmethod vnop-remove ((dir ram-node) name vnode) (declare (ignore vnode)) (drop-child dir name))
(defmethod vnop-rmdir ((dir ram-node) name vnode) (declare (ignore vnode)) (drop-child dir name))

(defmethod vnop-rename ((from-dir ram-node) from-name vnode (to-dir ram-node) to-name)
  (drop-child to-dir to-name)
  (drop-child from-dir from-name)
  (add-child to-dir to-name vnode))

(defmethod vnop-setattr ((n ram-node) &key mode uid gid)
  (when mode (setf (node-mode n) (logand mode #o7777)))
  (when (and uid (/= uid -1)) (setf (node-uid n) uid))
  (when (and gid (/= gid -1)) (setf (node-gid n) gid))
  0)

(defun mkdirs (root path)
  (let ((n root))
    (dolist (part (split-path path) n)
      (setf n (or (vnop-lookup n part) (vnop-mkdir n part #o755))))))

(defclass dev-node (vnode)
  ((device :initarg :device :reader node-device)
   (mode :initarg :mode :reader node-mode)))

(defmethod initialize-instance :after ((n dev-node) &key)
  (setf (vnode-id n) (prog1 *next-ino* (incf *next-ino*))))

(defun console-io (number fd sap count)
  (sb-alien:alien-funcall
   (sb-alien:extern-alien "__syscall" (function sb-alien:long sb-alien:long sb-alien:long sb-alien:long sb-alien:long
                                                sb-alien:long sb-alien:long sb-alien:long))
   number fd (sb-sys:sap-int sap) count 0 0 0))

(defmethod vnop-read ((n dev-node) offset count)
  (declare (ignore offset))
  (ecase (node-device n)
    (:null (make-array 0 :element-type '(unsigned-byte 8)))
    (:random
     (let ((buffer (make-array count :element-type '(unsigned-byte 8))))
       (when (/= count (sb-sys:with-pinned-objects (buffer)
                       (sb-alien:alien-funcall
                        (sb-alien:extern-alien "__machdep" (function sb-alien:long sb-alien:long sb-alien:long sb-alien:long))
                        16 (sb-sys:sap-int (sb-sys:vector-sap buffer)) count)))
         (fail :eio))
       buffer))
    (:console
     (let ((buffer (make-array count :element-type '(unsigned-byte 8))))
       (let ((got (sb-sys:with-pinned-objects (buffer) (console-io 3 0 (sb-sys:vector-sap buffer) count))))
         (when (minusp got) (fail :eintr))
         (subseq buffer 0 got))))))

(defmethod vnop-write ((n dev-node) offset octets)
  (declare (ignore offset))
  (when (eq (node-device n) :console)
    (let ((buffer (coerce octets '(simple-array (unsigned-byte 8) (*)))))
      (sb-sys:with-pinned-objects (buffer) (console-io 4 1 (sb-sys:vector-sap buffer) (length buffer)))))
  (length octets))

(defmethod vnop-getattr ((n dev-node))
  (make-vattr :mode (logior #o020000 (node-mode n)) :rdev (case (node-device n) (:null #x103) (:random #x109) (t #x501))))

(defmethod vnop-truncate ((n dev-node) size) (declare (ignore size)) 0)

(defun load-cpio (root sap size)
  (let ((at 0))
    (flet ((field (i) (parse-integer (map 'string #'code-char
                                          (loop for k below 8 collect (sb-sys:sap-ref-8 sap (+ at 6 (* 8 i) k))))
                                     :radix 16))
           (text (start length) (map 'string #'code-char (loop for k below length collect (sb-sys:sap-ref-8 sap (+ start k))))))
      (loop while (and (<= (+ at 110) size) (string= (text at 6) "070701"))
            do (let* ((mode (field 1)) (filesize (field 6)) (namesize (field 11))
                      (name (text (+ at 110) (1- namesize)))
                      (data (logandc2 (+ at 110 namesize 3) 3)))
                 (when (string= name "TRAILER!!!") (return))
                 (case (logand mode #o170000)
                   (#o040000 (mkdirs root name))
                   (#o100000
                    (let* ((parts (split-path name))
                           (dir (mkdirs root (format nil "~{~a~^/~}" (butlast parts))))
                           (n (vnop-create dir (car (last parts)) (logand mode #o7777))))
                      (setf (node-external n) (sb-sys:sap+ sap data) (node-size n) filesize))))
                 (setf at (logandc2 (+ data filesize 3) 3)))))))
