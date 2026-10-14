(in-package #:finch/apfs)

(defclass apfs-vnode (vfs:vnode)
  ((volume :initarg :volume :reader vnode-volume)
   (inode :initarg :inode :reader vnode-inode)))

(defvar *vnodes* (make-hash-table :test 'equal))

(defun apfs-vnode (v id)
  (or (gethash (cons (volume-uuid v) id) *vnodes*)
      (let ((i (inode v id)))
        (setf (gethash (cons (volume-uuid v) id) *vnodes*)
              (make-instance 'apfs-vnode :volume v :inode i :id id
                                         :type (case (logand (inode-mode i) #o170000)
                                                 (#o040000 :vdir) (#o120000 :vlnk) (#o100000 :vreg) (t :vchr)))))))

(defmethod vfs:vnop-lookup ((dir apfs-vnode) name)
  (let* ((v (vnode-volume dir))
         (entry (find name (directory-entries v (vfs:vnode-id dir)) :key #'entry-name
                                                                    :test (lambda (a b) (name-equal v a b)))))
    (and entry (apfs-vnode v (entry-file-id entry)))))

(defmethod vfs:vnop-readdir ((dir apfs-vnode))
  (let ((v (vnode-volume dir)))
    (mapcar (lambda (e) (cons (entry-name e) (apfs-vnode v (entry-file-id e))))
            (directory-entries v (vfs:vnode-id dir)))))

(defmethod vfs:vnop-read ((n apfs-vnode) offset count)
  (read-file (vnode-volume n) (vfs:vnode-id n) :start offset :end (+ offset count)))

(defmethod vfs:vnop-write ((n apfs-vnode) offset octets)
  (declare (ignore offset octets))
  (vfs:fail :erofs))

(defmethod vfs:vnop-readlink ((n apfs-vnode)) (readlink (vnode-volume n) (vfs:vnode-id n)))

(defmethod vfs:vnop-getattr ((n apfs-vnode))
  (let* ((i (vnode-inode n))
         (dir (eq (vfs:vnode-type n) :vdir))
         (links (if dir (+ 2 (inode-nlink i)) (inode-nlink i))))
    (vfs:make-vattr :mode (inode-mode i) :uid (inode-owner i) :gid (inode-group i) :nlink links
                    :size (cond (dir (* 32 links))
                                ((eq (vfs:vnode-type n) :vlnk)
                                 (length (sb-ext:string-to-octets (vfs:vnop-readlink n) :external-format :utf-8)))
                                (t (inode-size i)))
                    :mtime (inode-mod-time i))))

(defun mount-volume (v path)
  (vfs:vfs-mount (apfs-vnode v +root-dir-ino-num+) path))

(defun mount-volumes ()
  (loop for vol in (iokit:find-entries 'apple-apfs-volume)
        for v = (apfs-volume vol)
        for path = (format nil "/Volumes/~a" (volume-name v))
        do (vfs:vfs-mkdir path #o755)
           (mount-volume v path)
        collect path))
