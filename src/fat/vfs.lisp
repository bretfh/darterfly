(in-package #:darterfly/fat)

(defclass fat-vnode (vfs:vnode)
  ((volume :initarg :volume :reader vnode-volume)
   (dir :initarg :dir :initform nil :reader vnode-dir)
   (slot :initarg :slot :initform nil :reader vnode-slot)))

(defvar *vnodes* (make-hash-table :test 'equal :synchronized t))

(defun vnode (v dir entry)
  (let ((key (list v dir (entry-slot entry))))
    (or (gethash key *vnodes*)
        (setf (gethash key *vnodes*)
              (make-instance 'fat-vnode :volume v :dir dir :slot (entry-slot entry)
                                        :type (if (entry-directory-p entry) :vdir :vreg)
                                        :id (+ (* dir 65536) (entry-slot entry)))))))

(defun root-vnode (v)
  (make-instance 'fat-vnode :volume v :type :vdir :id (volume-root-cluster v)))

(defun vnode-entry (n)
  (or (find (vnode-slot n) (entries (vnode-volume n) (vnode-dir n)) :key #'entry-slot)
      (vfs:fail :enoent)))

(defun vnode-cluster (n)
  (if (vnode-dir n) (entry-cluster (vnode-entry n)) (volume-root-cluster (vnode-volume n))))

(defmethod vfs:vnop-lookup ((dir fat-vnode) name)
  (let* ((v (vnode-volume dir)) (cluster (vnode-cluster dir)) (e (lookup v cluster name)))
    (and e (vnode v cluster e))))

(defmethod vfs:vnop-readdir ((dir fat-vnode))
  (let* ((v (vnode-volume dir)) (cluster (vnode-cluster dir)))
    (mapcar (lambda (e) (cons (entry-name e) (vnode v cluster e))) (entries v cluster))))

(defmethod vfs:vnop-read ((n fat-vnode) offset count)
  (read-file (vnode-volume n) (vnode-entry n) offset (+ offset count)))

(defmethod vfs:vnop-write ((n fat-vnode) offset octets)
  (let ((v (vnode-volume n)))
    (with-volume (v) (write-file v (vnode-dir n) (vnode-entry n) offset octets))))

(defmethod vfs:vnop-truncate ((n fat-vnode) size)
  (unless (eq (vfs:vnode-type n) :vreg) (vfs:fail :einval))
  (let ((v (vnode-volume n)))
    (with-volume (v) (truncate-file v (vnode-dir n) (vnode-entry n) size))))

(defmethod vfs:vnop-getattr ((n fat-vnode))
  (if (eq (vfs:vnode-type n) :vdir)
      (vfs:make-vattr :mode #o040755 :nlink 2 :size (cluster-bytes (vnode-volume n)))
      (vfs:make-vattr :mode #o100644 :size (entry-size (vnode-entry n)))))

(defmethod vfs:vnop-create ((dir fat-vnode) name mode)
  (declare (ignore mode))
  (let ((v (vnode-volume dir)) (cluster (vnode-cluster dir)))
    (with-volume (v) (vnode v cluster (make-entry v cluster name)))))

(defmethod vfs:vnop-mkdir ((dir fat-vnode) name mode)
  (declare (ignore mode))
  (let ((v (vnode-volume dir)) (cluster (vnode-cluster dir)))
    (with-volume (v) (vnode v cluster (make-entry v cluster name :directory t)))))

(defmethod vfs:vnop-remove ((dir fat-vnode) name vnode)
  (let ((v (vnode-volume dir)))
    (with-volume (v)
      (remove-entry v (vnode-cluster dir) (vnode-entry vnode))
      (remhash (list v (vnode-dir vnode) (vnode-slot vnode)) *vnodes*))))

(defmethod vfs:vnop-rmdir ((dir fat-vnode) name vnode)
  (let ((v (vnode-volume dir)))
    (when (entries v (vnode-cluster vnode)) (vfs:fail :enotempty))
    (vfs:vnop-remove dir name vnode)))

(defmethod vfs:vnop-rename ((from fat-vnode) from-name vnode (to fat-vnode) to-name)
  (let ((v (vnode-volume from)))
    (unless (eq v (vnode-volume to)) (vfs:fail :exdev))
    (with-volume (v)
      (let* ((old (vnode-entry vnode))
             (to-cluster (vnode-cluster to))
             (existing (lookup v to-cluster to-name)))
        (when existing (remove-entry v to-cluster existing))
        (let ((new (make-entry v to-cluster to-name)))
          (update-entry v to-cluster new :cluster (entry-cluster old) :size (entry-size old))
          (when (entry-directory-p old)
            (let ((d (read-chain v to-cluster)) (at (* 32 (entry-slot new))))
              (setf (aref d (+ at 11)) +attr-directory+)
              (write-slot v to-cluster (entry-slot new) (subseq d at (+ at 32))))))
        (remove-entry v (vnode-cluster from) old :free nil)
        (remhash (list v (vnode-dir vnode) (vnode-slot vnode)) *vnodes*)))))

(defun mount (read write path)
  (let ((v (open-volume read write)))
    (vfs:vfs-mount (root-vnode v) path)
    v))

(defun fat-media-p (media)
  (let ((boot (devices:media-read media 0 +sector+)))
    (and (= (u boot 510 2) #xAA55) (string= (map 'string #'code-char (subseq boot 82 90)) "FAT32   "))))

(defun whole-blocks (read write)
  (lambda (at octets)
    (let ((first (* +sector+ (floor at +sector+)))
          (end (* +sector+ (ceiling (+ at (length octets)) +sector+))))
      (if (and (= first at) (= end (+ at (length octets))))
          (funcall write at octets)
          (let ((blocks (funcall read first (- end first))))
            (replace blocks octets :start1 (- at first))
            (funcall write first blocks))))))

(defun mount-esp (&optional (path "/Volumes/EFI"))
  (let ((media (find-if (lambda (m) (and (or (devices:get-property m "Whole")
                                              (equal (devices:get-property m "Content") darterfly/gpt:+esp-type+))
                                          (fat-media-p m)))
                        (devices:find-entries 'devices:media))))
    (when media
      (vfs:vfs-mkdirs path)
      (let ((read (lambda (at length) (devices:media-read media at length))))
        (mount read (whole-blocks read (lambda (at octets) (devices:media-write media at octets))) path)))))

(defun put-entries (v entries)
  (dolist (e entries v)
    (destructuring-bind (kind path &optional octets) e
      (let* ((slash (position #\/ path :from-end t))
             (parent (if slash (entry-cluster (resolve v (subseq path 0 slash))) (volume-root-cluster v)))
             (name (if slash (subseq path (1+ slash)) path)))
        (ecase kind
          (:dir (unless (lookup v parent name) (make-entry v parent name :directory t)))
          (:file (let ((entry (or (lookup v parent name) (make-entry v parent name))))
                   (truncate-file v parent entry 0)
                   (write-file v parent (lookup v parent name) 0 octets))))))))

(defun newfs (path &key (size (* 256 1048576)) (label "EFI") entries)
  (with-open-file (s path :direction :output :element-type '(unsigned-byte 8) :if-exists :supersede))
  (multiple-value-bind (read write) (file-store path)
    (let ((v (format-volume read write size label)))
      (with-volume (v) (put-entries v entries))
      path)))

(pushnew 'forget-vnodes sb-ext:*save-hooks*)

(defun forget-vnodes () (clrhash *vnodes*))
