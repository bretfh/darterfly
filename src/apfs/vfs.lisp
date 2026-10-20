(in-package #:darterfly/apfs)

(defvar *root-media* nil)

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

(defun mount-volumes (&key writable)
  (loop for vol in (devices:find-entries 'apfs-volume-media)
        for v = (apfs-volume vol)
        for path = (format nil "/Volumes/~a" (volume-name v))
        unless (eq vol *root-media*)
        do (vfs:vfs-mkdirs path)
           (if writable
               (let ((media vol))
                 (mount-writable (lambda (at length) (devices:media-read media at length))
                                 (lambda (at octets) (devices:media-write media at octets))
                                 path
                                 (lambda () (devices:media-flush media))))
               (mount-volume v path))
        and collect path))

(defclass apfs-wvnode (vfs:vnode)
  ((mount :initarg :mount :reader vnode-mount)))

(defvar *wvnodes* (make-hash-table :test 'equal))

(defun wvnode (w id)
  (or (gethash (cons w id) *wvnodes*)
      (setf (gethash (cons w id) *wvnodes*)
            (make-instance 'apfs-wvnode :mount w :id id
                                        :type (case (logand (inode-field w id 80 2) #o170000)
                                                (#o040000 :vdir) (#o120000 :vlnk) (#o100000 :vreg) (t :vchr))))))

(defvar *batch* :none)
(defvar *dirty* nil)
(defvar *dirty-lock* (sb-thread:make-mutex :name "apfs dirty"))
(defvar *syncer* nil)

(defun sync-volumes ()
  (vfs::with-vfs
    (mapc #'wcommit (sb-thread:with-mutex (*dirty-lock*) (shiftf *dirty* nil)))))

(defun start-syncer (&optional (interval 1))
  (unless *syncer*
    (push #'sync-volumes vfs:*syncers*)
    (push #'vfs:vfs-sync sb-ext:*exit-hooks*)
    (setf *syncer* (sb-thread:make-thread (lambda () (loop (sleep interval) (sync-volumes))) :name "apfs syncer"))))

(defmacro with-commit ((w vnode) &body body)
  `(let ((,w (vnode-mount ,vnode)))
     (prog1 (progn ,@body)
       (cond ((listp *batch*) (pushnew ,w *batch*))
             (*syncer* (sb-thread:with-mutex (*dirty-lock*) (pushnew ,w *dirty*)))
             (t (wcommit ,w))))))

(defmacro with-batch (&body body)
  `(let ((*batch* nil))
     (multiple-value-prog1 (progn ,@body)
       (mapc #'wcommit *batch*))))

(defmethod vfs:vnop-lookup ((dir apfs-wvnode) name)
  (let* ((w (vnode-mount dir)) (id (wlookup w (vfs:vnode-id dir) name)))
    (and id (wvnode w id))))

(defmethod vfs:vnop-readdir ((dir apfs-wvnode))
  (let ((w (vnode-mount dir)))
    (mapcar (lambda (e) (cons (car e) (wvnode w (cdr e)))) (wentries w (vfs:vnode-id dir)))))

(defmethod vfs:vnop-read ((n apfs-wvnode) offset count)
  (wread (vnode-mount n) (vfs:vnode-id n) offset (+ offset count)))

(defmethod vfs:vnop-write ((n apfs-wvnode) offset octets)
  (with-commit (w n) (wwrite w (vfs:vnode-id n) offset octets)))

(defmethod vfs:vnop-truncate ((n apfs-wvnode) size)
  (unless (eq (vfs:vnode-type n) :vreg) (vfs:fail :einval))
  (with-commit (w n) (wtruncate w (vfs:vnode-id n) size)))

(defun wreadlink (w id)
  (let ((v (gethash (octets (j-key id +apfs-type-xattr+) (le 21 2) (c-octets +symlink-xattr+)) (wvolume-records w))))
    (unless v (vfs:fail :einval))
    (c-string v 4 (+ 4 (u16 v 2)))))

(defmethod vfs:vnop-readlink ((n apfs-wvnode)) (wreadlink (vnode-mount n) (vfs:vnode-id n)))

(defmethod vfs:vnop-getattr ((n apfs-wvnode))
  (let* ((w (vnode-mount n)) (id (vfs:vnode-id n))
         (dir (eq (vfs:vnode-type n) :vdir))
         (links (if dir (+ 2 (inode-field w id 56 4)) (inode-field w id 56 4))))
    (vfs:make-vattr :mode (inode-field w id 80 2) :uid (inode-field w id 72 4) :gid (inode-field w id 76 4) :nlink links
                    :size (cond (dir (* 32 links))
                                ((eq (vfs:vnode-type n) :vlnk) (length (sb-ext:string-to-octets (wreadlink w id) :external-format :utf-8)))
                                (t (let ((d (inode-dstream w id))) (if d (u64 d 0) 0))))
                    :mtime (inode-field w id 24 8))))

(defmethod vfs:vnop-create ((dir apfs-wvnode) name mode)
  (with-commit (w dir) (wvnode w (wcreate w (vfs:vnode-id dir) name :file :mode mode))))

(defmethod vfs:vnop-mkdir ((dir apfs-wvnode) name mode)
  (with-commit (w dir) (wvnode w (wcreate w (vfs:vnode-id dir) name :dir :mode mode))))

(defmethod vfs:vnop-symlink ((dir apfs-wvnode) name target)
  (with-commit (w dir) (wvnode w (wcreate w (vfs:vnode-id dir) name :symlink :mode #o755 :target target))))

(defun adopt-open-files ()
  "Rebuild accounting at a quiesced upgrade boundary, before file operations resume.
Count descriptions once per inode and descriptors once per description. Calling
this during a close in progress is invalid: its descriptor has already detached."
  (vfs::with-vfs
    (sb-thread:with-mutex (vfs::*files-lock*)
      (let ((descriptions (make-hash-table :test 'eq))
            (volumes (make-hash-table :test 'eq)))
        (maphash (lambda (fd file)
                   (declare (ignore fd))
                   (incf (gethash file descriptions 0))) vfs::*files*)
        (maphash (lambda (file count)
                   (declare (ignore count))
                   (let ((node (vfs::file-vnode file)))
                     (when (typep node 'apfs-wvnode)
                       (let* ((volume (vnode-mount node))
                              (opens (or (gethash volume volumes)
                                         (setf (gethash volume volumes) (make-hash-table)))))
                         (incf (gethash (vfs:vnode-id node) opens 0)))))) descriptions)
        ;; Publish only after the complete inventory has been constructed.
        (maphash (lambda (file count) (setf (vfs::file-refs file) count)) descriptions)
        (maphash (lambda (volume opens) (setf (gethash volume *open-inodes*) opens)) volumes)
        (setf vfs::*file-lifetime-version* 2)
        (list :descriptions (hash-table-count descriptions) :volumes (hash-table-count volumes))))))

(defmethod vfs:vnop-open ((n apfs-wvnode))
  (incf (gethash (vfs:vnode-id n) (wvolume-opens (vnode-mount n)) 0)))

(defmethod vfs:vnop-close ((n apfs-wvnode))
  (vfs::with-vfs
    (let* ((w (vnode-mount n)) (id (vfs:vnode-id n)))
      (assert (plusp (gethash id (wvolume-opens w) 0)))
      (when (zerop (decf (gethash id (wvolume-opens w))))
        (remhash id (wvolume-opens w))
        (when (and (not (eq (vfs:vnode-type n) :vdir))
                   (zerop (inode-field w id 56 4)))
          (with-commit (w n) (wdispose w id))
          (remhash (cons w id) *wvnodes*))))))

(defmethod vfs:vnop-remove ((dir apfs-wvnode) name vnode)
  (with-commit (w dir)
    (wremove w (vfs:vnode-id dir) name (vfs:vnode-id vnode))
    (unless (plusp (gethash (vfs:vnode-id vnode) (wvolume-opens w) 0))
      (remhash (cons w (vfs:vnode-id vnode)) *wvnodes*))))

(defmethod vfs:vnop-rmdir ((dir apfs-wvnode) name vnode)
  (with-commit (w dir) (wremove w (vfs:vnode-id dir) name (vfs:vnode-id vnode)) (remhash (cons w (vfs:vnode-id vnode)) *wvnodes*)))

(defmethod vfs:vnop-rename ((from apfs-wvnode) from-name vnode (to apfs-wvnode) to-name)
  (unless (eq (vnode-mount from) (vnode-mount to)) (vfs:fail :exdev))
  (with-commit (w from) (wrename w (vfs:vnode-id from) from-name (vfs:vnode-id vnode) (vfs:vnode-id to) to-name)))

(defmethod vfs:vnop-setattr ((n apfs-wvnode) &key mode uid gid)
  (with-commit (w n)
    (update-inode w (vfs:vnode-id n)
                  :mode (and mode (logior (logand (inode-field w (vfs:vnode-id n) 80 2) #o170000) (logand mode #o7777)))
                  :owner (and uid (/= uid -1) uid) :group (and gid (/= gid -1) gid))
    0))

(defun mount-writable (read write path &optional flush)
  (let ((w (make-wvolume (open-writable read write flush))))
    (vfs:vfs-mount (wvnode w +root-dir-ino-num+) path)
    w))
