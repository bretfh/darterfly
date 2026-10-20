(defpackage #:darterfly/vfs
  (:use #:cl)
  (:export
   #:vfs-error #:vfs-errno #:fail
   #:vnode #:vnode-type #:vnode-id #:mount #:mount-path #:*mounts* #:vfs-mount #:vfs-unmount
   #:vnop-open #:vnop-close #:vnop-lookup #:vnop-readdir #:vnop-read #:vnop-write #:vnop-getattr #:vnop-readlink
   #:vnop-create #:vnop-mkdir #:vnop-symlink #:vnop-remove #:vnop-rmdir #:vnop-rename #:vnop-setattr #:vnop-truncate
   #:vattr #:make-vattr #:vattr-mode #:vattr-uid #:vattr-gid #:vattr-size #:vattr-nlink #:vattr-mtime #:vattr-rdev
   #:namei #:namei-at #:vfs-open-at #:vfs-remove-at #:vfs-open #:vfs-close #:vfs-read #:vfs-write #:vfs-stat #:vfs-readdir #:vfs-readlink #:vfs-mkdir
   #:vfs-unlink #:vfs-rename #:vfs-chdir #:vfs-getcwd #:*root*
   #:vfs-symlink #:vfs-remove #:vfs-lseek #:vfs-fstat #:vfs-realpath #:make-ram-node
   #:make-devfs #:make-kernel-dir #:vfs-mkdirs #:vfs-start #:make-procfs #:make-host-root #:fd-vnode #:*umask* #:errno-code #:*syncers* #:vfs-sync))
(in-package #:darterfly/vfs)

(define-condition vfs-error (error)
  ((errno :initarg :errno :reader vfs-errno))
  (:report (lambda (c s) (format s "~(~a~)" (vfs-errno c)))))

(defun fail (errno) (error 'vfs-error :errno errno))

(defclass vnode ()
  ((type :initarg :type :accessor vnode-type)
   (id :initarg :id :initform 0 :accessor vnode-id)))

(defstruct vattr (mode 0) (uid 0) (gid 0) (size 0) (nlink 1) (mtime 0) (rdev 0))

;; One retain per open file description, independent of descriptor duplication.
(defgeneric vnop-open (vnode) (:method ((v vnode)) nil))
(defgeneric vnop-close (vnode) (:method ((v vnode)) nil))
(defgeneric vnop-lookup (dir name))
(defgeneric vnop-readdir (dir))
(defgeneric vnop-read (vnode offset count))
(defgeneric vnop-write (vnode offset octets))
(defgeneric vnop-getattr (vnode))
(defgeneric vnop-readlink (vnode)
  (:method ((v vnode)) (fail :einval)))
(defgeneric vnop-create (dir name mode)
  (:method ((dir vnode) name mode) (declare (ignore name mode)) (fail :erofs)))
;; Special nodes are explicit: unsupported filesystems must not create a
;; regular file which merely looks like a socket to one caller.
(defgeneric vnop-mksocket (dir name mode)
  (:method ((dir vnode) name mode)
    (declare (ignore name mode)) (fail :eopnotsupp)))
(defgeneric vnop-mkdir (dir name mode)
  (:method ((dir vnode) name mode) (declare (ignore name mode)) (fail :erofs)))
(defgeneric vnop-symlink (dir name target)
  (:method ((dir vnode) name target) (declare (ignore name target)) (fail :erofs)))
(defgeneric vnop-remove (dir name vnode)
  (:method ((dir vnode) name vnode) (declare (ignore name vnode)) (fail :erofs)))
(defgeneric vnop-rmdir (dir name vnode)
  (:method ((dir vnode) name vnode) (declare (ignore name vnode)) (fail :erofs)))
(defgeneric vnop-rename (from-dir from-name vnode to-dir to-name)
  (:method ((from-dir vnode) from-name vnode to-dir to-name)
    (declare (ignore from-name vnode to-dir to-name)) (fail :exdev)))
(defgeneric vnop-setattr (vnode &key mode uid gid)
  (:method ((v vnode) &key mode uid gid) (declare (ignore mode uid gid)) (fail :erofs)))
(defgeneric vnop-truncate (vnode size)
  (:method ((v vnode) size) (declare (ignore size)) (fail :erofs)))

(defstruct mount path root covered)

(defvar *mounts* nil)
(defvar *root* nil)
(defvar *lock* (sb-thread:make-mutex :name "vfs"))

(defmacro with-vfs (&body body)
  `(sb-thread:with-recursive-lock (*lock*) ,@body))

(defvar *cwd* nil)

(defun mounted-on (vnode)
  (find vnode *mounts* :key #'mount-covered))

(defun vfs-mount (root path)
  (with-vfs
    (if (string= path "/")
        (setf *root* root *cwd* (list (cons "" root)))
        (let ((covered (namei path)))
          (unless (eq (vnode-type covered) :vdir) (fail :enotdir))
          (push (make-mount :path path :root root :covered covered) *mounts*)))
    root))

(defun vfs-unmount (path)
  (with-vfs (setf *mounts* (remove path *mounts* :key #'mount-path :test #'string=))))

(defvar *umask* #o022)

(defvar *syncers* nil)

(defun vfs-sync () (mapc #'funcall *syncers*) 0)

(defun split-path (path)
  (remove "" (uiop:split-string path :separator "/") :test #'string=))

(defun cross (vnode)
  (let ((m (mounted-on vnode)))
    (if m (mount-root m) vnode)))

(defun walk (stack parts follow depth)
  (loop
    (when (null parts) (return stack))
    (let* ((name (pop parts))
           (here (cdr (first stack))))
      (when (> (length name) 255) (fail :enametoolong))
      (cond ((string= name "."))
            ((string= name "..") (when (rest stack) (pop stack)))
            (t
             (unless (eq (vnode-type here) :vdir) (fail :enotdir))
             (let ((next (cross (or (vnop-lookup here name) (fail :enoent)))))
               (if (and (eq (vnode-type next) :vlnk) (or parts follow))
                   (progn
                     (when (> depth 32) (fail :eloop))
                     (let ((target (vnop-readlink next)))
                       (setf stack (walk (if (and (plusp (length target)) (char= (char target 0) #\/)) (last stack) stack)
                                         (split-path target) t (1+ depth)))))
                   (push (cons name next) stack))))))))

(defun namei (path &key (follow t))
  (with-vfs
    (let ((start (if (and (plusp (length path)) (char= (char path 0) #\/)) (last *cwd*) *cwd*)))
      (cdr (first (walk start (split-path path) follow 0))))))

(defun namei-stack (path &key (follow t))
  (with-vfs
    (let ((start (if (and (plusp (length path)) (char= (char path 0) #\/)) (last *cwd*) *cwd*)))
      (walk start (split-path path) follow 0))))

(defun namei-parent (path)
  (let* ((parts (split-path path))
         (leaf (car (last parts))))
    (unless leaf (fail :eexist))
    (when (member leaf '("." "..") :test #'string=) (fail :einval))
    (when (> (length leaf) 255) (fail :enametoolong))
    (let ((parent (namei (concatenate 'string (if (char= (char path 0) #\/) "/" "")
                                      (format nil "~{~a~^/~}" (butlast parts))))))
      (unless (eq (vnode-type parent) :vdir) (fail :enotdir))
      (values parent leaf))))

(defun stack-path (stack)
  (if (null (rest stack)) "/" (format nil "~{/~a~}" (reverse (mapcar #'car (butlast stack))))))

(defstruct file vnode (offset 0) flags (refs 1) stack listing)

(defvar *files* (make-hash-table))
;; Version 2 counts every descriptor reference and retains open APFS inodes.
;; A retained version-1 world must adopt descriptions at save quiescence.
(defvar *file-lifetime-version* 2)
;; Descriptor-table operations never wait for filesystem I/O. Lock order is
;; VFS -> files; no files-lock owner may acquire VFS.
(defvar *files-lock* (sb-thread:make-mutex :name "vfs descriptors"))
(defconstant +first-fd+ 3)

(defun install-locked (file from)
  (loop for fd from from below 4096
        unless (gethash fd *files*) do (setf (gethash fd *files*) file) (return fd)
        finally (fail :emfile)))

(defun install (file &optional (from +first-fd+))
  (sb-thread:with-mutex (*files-lock*) (install-locked file from)))

(defun fd-file (fd)
  (sb-thread:with-mutex (*files-lock*)
    (or (gethash fd *files*) (fail :ebadf))))

(defun fd-vnode (fd) (file-vnode (fd-file fd)))

(defun lookup-or-nil (path &key (follow t))
  (handler-case (namei path :follow follow)
    (vfs-error (e) (if (eq (vfs-errno e) :enoent) nil (error e)))))

(defun vfs-open (path flags mode)
  (with-vfs
    (let ((vnode (lookup-or-nil path :follow
                   (not (or (getf flags :nofollow)
                            (and (getf flags :creat) (getf flags :excl)))))))
      (when (and vnode (getf flags :creat) (getf flags :excl)) (fail :eexist))
      (unless vnode
        (unless (getf flags :creat) (fail :enoent))
        (multiple-value-bind (parent leaf) (namei-parent path)
          (setf vnode (vnop-create parent leaf (logand mode #o7777 (lognot *umask*))))))
      (when (and (getf flags :nofollow) (eq (vnode-type vnode) :vlnk))
        (fail :eloop))
      (when (eq (vnode-type vnode) :vsock) (fail :enxio))
    (when (and (getf flags :directory) (not (eq (vnode-type vnode) :vdir))) (fail :enotdir))
      (when (and (eq (vnode-type vnode) :vdir) (not (eq (getf flags :access) :rdonly)))
        (fail :eisdir))
      (when (and (getf flags :trunc) (eq (vnode-type vnode) :vreg) (not (eq (getf flags :access) :rdonly)))
        (vnop-truncate vnode 0))
      (vnop-open vnode)
      (let ((installed nil))
        (unwind-protect
            (prog1 (install (make-file :vnode vnode :flags flags
                     :stack (and (eq (vnode-type vnode) :vdir) (namei-stack path))))
              (setf installed t))
          (unless installed (vnop-close vnode)))))))

(defun vfs-close (fd)
  ;; Detach atomically, then reclaim outside the descriptor-table lock.
  ;; RAM and device closes must not wait for unrelated filesystem I/O.
  (let ((last (sb-thread:with-mutex (*files-lock*)
                (let ((file (or (gethash fd *files*) (fail :ebadf))))
                  (remhash fd *files*)
                  (when (zerop (decf (file-refs file))) file)))))
    (when last (vnop-close (file-vnode last))))
  0)

(defun readable-p (file) (not (eq (getf (file-flags file) :access) :wronly)))
(defun writable-p (file) (not (eq (getf (file-flags file) :access) :rdonly)))

(defun vfs-read (fd count &optional offset)
  (let ((device
          (with-vfs
            (let* ((f (fd-file fd)) (v (file-vnode f)))
              (unless (eq (vnode-type v) :vchr)
                (when (eq (vnode-type v) :vdir) (fail :eisdir))
                (unless (readable-p f) (fail :ebadf))
                (let ((data (vnop-read v (or offset (file-offset f)) count)))
                  (unless offset (incf (file-offset f) (length data)))
                  (return-from vfs-read data)))
              v))))
    (vnop-read device 0 count)))

(defun vfs-write (fd octets &optional offset)
  (with-vfs
    (let* ((f (fd-file fd)) (v (file-vnode f)))
      (unless (writable-p f) (fail :ebadf))
      (let ((at (cond (offset)
                      ((getf (file-flags f) :append) (vattr-size (vnop-getattr v)))
                      (t (file-offset f)))))
        (vnop-write v at octets)
        (unless offset (setf (file-offset f) (+ at (length octets))))
        (length octets)))))

(defun vfs-lseek (fd offset whence)
  (with-vfs
    (let* ((f (fd-file fd))
           (base (ecase whence (0 0) (1 (file-offset f)) (2 (vattr-size (vnop-getattr (file-vnode f)))))))
      (when (eq (vnode-type (file-vnode f)) :vchr) (fail :espipe))
      (when (minusp (+ base offset)) (fail :einval))
      (setf (file-offset f) (+ base offset)))))

(defun vfs-stat (path &key (follow t)) (with-vfs (vnop-getattr (namei path :follow follow))))
(defun vfs-fstat (fd) (with-vfs (vnop-getattr (file-vnode (fd-file fd)))))

(defun vfs-readlink (path)
  (with-vfs
    (let ((v (namei path :follow nil)))
      (unless (eq (vnode-type v) :vlnk) (fail :einval))
      (vnop-readlink v))))

(defun vfs-symlink (target path)
  (with-vfs
    (when (lookup-or-nil path :follow nil) (fail :eexist))
    (multiple-value-bind (parent leaf) (namei-parent path)
      (vnop-symlink parent leaf target))
    0))

(defun vfs-mkdir (path mode)
  (with-vfs
    (when (lookup-or-nil path :follow nil) (fail :eexist))
    (multiple-value-bind (parent leaf) (namei-parent path)
      (vnop-mkdir parent leaf (logand mode #o7777 (lognot *umask*))))
    0))

(defun busy-p (vnode)
  (or (eq vnode *root*) (eq vnode (cdr (first *cwd*))) (mounted-on vnode)
      (find vnode *mounts* :key #'mount-root)))

(defun vfs-remove (path directory)
  (with-vfs
    (let ((v (namei path :follow nil)))
      (when (busy-p v) (fail :ebusy))
      (multiple-value-bind (parent leaf) (namei-parent path)
        (cond (directory
               (unless (eq (vnode-type v) :vdir) (fail :enotdir))
               (when (vnop-readdir v) (fail :enotempty))
               (vnop-rmdir parent leaf v))
              (t
               (when (eq (vnode-type v) :vdir) (fail :eisdir))
               (vnop-remove parent leaf v))))
      0)))

(defun vfs-unlink (path) (vfs-remove path nil))

(defun vfs-rename (from to)
  (with-vfs
    (let ((v (namei from :follow nil))
          (old (lookup-or-nil to :follow nil)))
      (multiple-value-bind (from-dir from-leaf) (namei-parent from)
        (multiple-value-bind (to-dir to-leaf) (namei-parent to)
          (when old
            (when (eq old v) (return-from vfs-rename 0))
            (when (and (eq (vnode-type v) :vdir) (not (eq (vnode-type old) :vdir))) (fail :enotdir))
            (when (and (not (eq (vnode-type v) :vdir)) (eq (vnode-type old) :vdir)) (fail :eisdir))
            (when (and (eq (vnode-type old) :vdir) (vnop-readdir old)) (fail :enotempty)))
          (when (and (eq (vnode-type v) :vdir)
                     (member v (mapcar #'cdr (namei-stack (namestring-parent to)))))
            (fail :einval))
          (vnop-rename from-dir from-leaf v to-dir to-leaf)
          0)))))

(defun namestring-parent (path)
  (let ((parts (split-path path)))
    (concatenate 'string (if (char= (char path 0) #\/) "/" "") (format nil "~{~a~^/~}" (butlast parts)))))

(defun vfs-chdir (path)
  (with-vfs
    (let ((stack (namei-stack path)))
      (unless (eq (vnode-type (cdr (first stack))) :vdir) (fail :enotdir))
      (setf *cwd* stack)
      0)))

(defun vfs-fchdir (fd)
  (with-vfs
    (let ((f (fd-file fd)))
      (unless (eq (vnode-type (file-vnode f)) :vdir) (fail :enotdir))
      (setf *cwd* (file-stack f))
      0)))

(defun vfs-getcwd () (with-vfs (stack-path *cwd*)))
(defun vfs-realpath (path) (with-vfs (stack-path (namei-stack path))))

(defun vfs-readdir (fd index)
  (with-vfs
    (let* ((f (fd-file fd))
           (v (file-vnode f)))
      (unless (eq (vnode-type v) :vdir) (fail :enotdir))
      (when (or (zerop index) (null (file-listing f)))
        (setf (file-listing f) (coerce (vnop-readdir v) 'vector)))
      (when (< index (length (file-listing f)))
        (aref (file-listing f) index)))))

(defun vfs-dup (fd &optional (from +first-fd+))
  (sb-thread:with-mutex (*files-lock*)
    (let ((file (or (gethash fd *files*) (fail :ebadf))))
      (prog1 (install-locked file from) (incf (file-refs file))))))

(defun vfs-dup2 (fd new)
  (let ((last
          (sb-thread:with-mutex (*files-lock*)
            (let ((file (or (gethash fd *files*) (fail :ebadf))))
              (unless (<= +first-fd+ new 4095) (fail :ebadf))
              (unless (= fd new)
                (let ((old (gethash new *files*)))
                  (incf (file-refs file))
                  (setf (gethash new *files*) file)
                  (when (and old (zerop (decf (file-refs old)))) old)))))))
    (when last (vnop-close (file-vnode last))))
  new)

(defun namei-at (fd path &key (follow t))
  "Resolve relative to an open directory without changing process cwd."
  (with-vfs
    (let* ((file (fd-file fd)) (stack (file-stack file)))
      (unless (eq (vnode-type (file-vnode file)) :vdir) (fail :enotdir))
      (cdr (first (walk stack (split-path path) follow 0))))))

(defun directory-stack (fd)
  (let ((file (fd-file fd)))
    (unless (eq (vnode-type (file-vnode file)) :vdir) (fail :enotdir))
    (file-stack file)))

(defun vfs-open-at (fd path flags mode)
  "Open relative to a directory vnode without changing process cwd."
  (with-vfs
    (let ((*cwd* (directory-stack fd)))
      (vfs-open path flags mode))))

(defun vfs-remove-at (fd path directory)
  "Remove a directory entry relative to an open directory vnode."
  (with-vfs
    (let ((*cwd* (directory-stack fd)))
      (vfs-remove path directory))))
