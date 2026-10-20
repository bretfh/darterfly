(in-package #:darterfly/bsd)

(defconstant +o-rdonly+ 0)
(defconstant +o-wronly+ 1)
(defconstant +o-rdwr+ 2)
(defconstant +o-append+ #x8)
(defconstant +o-creat+ #x200)
(defconstant +o-trunc+ #x400)
(defconstant +o-excl+ #x800)
(defconstant +o-nofollow+ #x100)
(defconstant +o-directory+ #x100000)

(defconstant +s-ifmt+ #o170000)
(defconstant +s-ifdir+ #o040000)
(defconstant +s-ifreg+ #o100000)
(defconstant +s-ififo+ #o010000)
(defconstant +s-iflnk+ #o120000)
(defconstant +s-ifchr+ #o020000)

(defun ensure-root ()
  (unless vfs:*root* (vfs:vfs-mount (vfs:make-host-root) "/")))

(defmacro vfs (&body body)
  `(handler-case (progn (ensure-root) ,@body)
     (vfs:vfs-error (e) (fail (vfs:vfs-errno e)))))

(defun vfs-flags (flags)
  (list :access (ecase (logand flags 3) (0 :rdonly) (1 :wronly) (2 :rdwr))
        :creat (logtest flags +o-creat+) :excl (logtest flags +o-excl+) :trunc (logtest flags +o-trunc+)
        :append (logtest flags +o-append+) :nonblock (logtest flags +o-nonblock+)
        :nofollow (logtest flags +o-nofollow+)
        :directory (logtest flags +o-directory+)))

(defclass vnode (file)
  ((fd :initarg :fd :reader vfs-fd)
   (access :initarg :access :initform 2 :reader file-access)
   (device :initarg :device :initform nil :reader device-p)
   (lock-key :initform nil :accessor file-lock-key)))

(defmethod file-read ((file vnode) count)
  (if (device-p file)
      (progn (sb-thread:release-mutex *bsd*)
             (unwind-protect (vfs (vfs:vfs-read (vfs-fd file) count))
               (sb-thread:grab-mutex *bsd*)))
      (vfs (vfs:vfs-read (vfs-fd file) count))))

(defmethod file-write ((file vnode) octets)
  (vfs (vfs:vfs-write (vfs-fd file) octets)))

(defmethod file-close ((file vnode))
  (vfs (vfs:vfs-close (vfs-fd file))))

(defun absolute (name)
  (if (and (plusp (length name)) (char= (char name 0) #\/))
      name
      (format nil "~a/~a" (string-right-trim "/" (proc-cwd *proc*)) name)))

(defun path (name)
  (format nil "~a~a" (string-right-trim "/" (proc-root *proc*)) (absolute name)))

(defun unroot (full)
  (let ((root (string-right-trim "/" (proc-root *proc*))))
    (if (and (plusp (length root)) (uiop:string-prefix-p root full))
        (let ((rest (subseq full (length root)))) (if (string= rest "") "/" rest))
        full)))

(defun mode-type (mode) (logand mode +s-ifmt+))

(defun open (name flags &optional (mode #o644))
  (syscall
    (when (zerop (length name)) (fail :enoent))
    (let ((fd (vfs (vfs:vfs-open (path name) (vfs-flags flags) mode))))
      (fd-alloc (make-instance 'vnode :fd fd :access (logand flags 3)
                                      :device (= (mode-type (vfs:vattr-mode (vfs (vfs:vfs-fstat fd)))) +s-ifchr+)
                                      :flags (logand flags +o-nonblock+))))))

(defun lseek (fd offset whence)
  (syscall
    (let ((file (fd-file fd)))
      (unless (typep file 'vnode) (fail :espipe))
      (vfs (vfs:vfs-lseek (vfs-fd file) offset (ecase whence (:set 0) (:cur 1) (:end 2)))))))

(defun stat-plist (attr id)
  (list :mode (vfs:vattr-mode attr) :size (vfs:vattr-size attr) :nlink (vfs:vattr-nlink attr)
        :ino id :mtime (floor (vfs:vattr-mtime attr) 1000000000)))

(defun stat-path (name follow)
  (vfs (let ((v (vfs:namei (path name) :follow follow)))
         (stat-plist (vfs:vnop-getattr v) (vfs:vnode-id v)))))

(defun stat (name) (syscall (stat-path name t)))
(defun lstat (name) (syscall (stat-path name nil)))

(defun fstat (fd)
  (syscall
    (let ((file (fd-file fd)))
      (if (typep file 'vnode)
          (vfs (let ((v (vfs:fd-vnode (vfs-fd file)))) (stat-plist (vfs:vnop-getattr v) (vfs:vnode-id v))))
          (list :mode (if (typep file 'socket) #o140000 +s-ififo+) :size 0 :nlink 1 :ino 0 :mtime 0)))))

(defun mkdir (name &optional (mode #o755))
  (syscall (vfs (vfs:vfs-mkdir (path name) mode)) 0))

(defun rmdir (name)
  (syscall (vfs (vfs:vfs-remove (path name) t)) 0))

(defun unlink (name)
  (syscall
    (handler-case (vfs (vfs:vfs-remove (path name) nil))
      (errno (e) (fail (if (eq (errno-name e) :eisdir) :eperm (errno-name e)))))
    0))

(defun rename (from to)
  (syscall (vfs (vfs:vfs-rename (path from) (path to))) 0))

(defun symlink (target name)
  (syscall (vfs (vfs:vfs-symlink target (path name))) 0))

(defun directory-vnode (name)
  (vfs (let ((v (vfs:namei (path name))))
         (unless (eq (vfs:vnode-type v) :vdir) (fail :enotdir))
         v)))

(defun readdir (name)
  (syscall (mapcar #'car (vfs (vfs:vnop-readdir (directory-vnode name))))))

(defun chdir (name)
  (syscall
    (directory-vnode name)
    (setf (proc-cwd *proc*) (unroot (vfs (vfs:vfs-realpath (path name)))))
    0))

(defun chroot (name)
  (syscall
    (directory-vnode name)
    (setf (proc-root *proc*) (vfs (vfs:vfs-realpath (path name)))
          (proc-cwd *proc*) "/")
    0))

(defun getcwd ()
  (proc-cwd *proc*))

;; POSIX record locks are owned by a process, not an open file description.
;; Closing ANY descriptor for an inode releases that process's locks on it.
(defvar *record-locks* (make-hash-table :test 'equal))
(defvar *record-lock-waiters* (make-hash-table :test 'eq))
(defmethod initialize-instance :after ((file vnode) &key)
  ;; A world's inherited console descriptors may no longer have local VFS
  ;; entries at teardown. Capture regular-file identity when the file opens.
  (let ((node (ignore-errors (vfs:fd-vnode (vfs-fd file)))))
    (when (and node (eq (vfs:vnode-type node) :vreg))
      (setf (file-lock-key file)
        (if (typep node 'vfs::host-node)
            (let ((stat (sb-posix:stat (vfs::host-path node))))
              (list :host (sb-posix:stat-dev stat) (sb-posix:stat-ino stat)))
            node)))))
(defun record-lock-key (file)
  (or (file-lock-key file) (fail :ebadf)))
(defmethod release-record-locks ((file vnode) proc)
  (let ((key (file-lock-key file)))
    (when key
      (let ((locks (remove proc (gethash key *record-locks*) :key #'first)))
        (if locks (setf (gethash key *record-locks*) locks)
            (remhash key *record-locks*))))))
(defun lock-overlaps-p (start end lock)
  (and (< start (fourth lock)) (< (third lock) end)))
(defun record-lock (fd command type whence start length)
  (syscall
    (unless (member type '(0 1 2)) (fail :einval))
    (let* ((file (vnode-file fd)) (key (record-lock-key file))
           (base (case whence
                   (0 0) (1 (vfs (vfs:vfs-lseek (vfs-fd file) 0 1)))
                   (2 (vfs:vattr-size (vfs (vfs:vfs-fstat (vfs-fd file)))))
                   (t (fail :einval))))
           (first (+ base start))
           (end (if (zerop length) (ash 1 63) (+ first length))))
      (when (minusp length) (rotatef first end))
      (unless (<= 0 first end (ash 1 63)) (fail :einval))
      (when (or (and (= type 0) (= (file-access file) 1))
                (and (= type 1) (= (file-access file) 0))) (fail :ebadf))
      (labels ((conflict ()
                 (find-if (lambda (lock)
                   (and (not (eq *proc* (first lock)))
                        (or (= type 1) (= (second lock) 1))
                        (lock-overlaps-p first end lock)))
                   (gethash key *record-locks*))))
        (when (= command 5)
          (return-from record-lock (and (/= type 2) (conflict))))
        (unless (= type 2)
          (loop for other = (conflict) while other do
            (unless (= command 7) (fail :eagain))
            (let ((owner (first other)) (seen nil))
              (loop while owner do
                (when (or (eq owner *proc*) (member owner seen)) (fail :edeadlk))
                (push owner seen)
                (setf owner (gethash owner *record-lock-waiters*))))
            (unwind-protect
                 (progn
                   (setf (gethash *proc* *record-lock-waiters*) (first other))
                   (sleep-until (lambda () (not (conflict)))))
              (remhash *proc* *record-lock-waiters*))
            (unless (eq file (fd-file fd)) (fail :ebadf))))
        (let ((locks nil))
          (dolist (lock (gethash key *record-locks*))
            (if (and (eq *proc* (first lock)) (lock-overlaps-p first end lock))
                (progn
                  (when (< (third lock) first)
                    (push (list *proc* (second lock) (third lock) first) locks))
                  (when (< end (fourth lock))
                    (push (list *proc* (second lock) end (fourth lock)) locks)))
                (push lock locks)))
          (unless (= type 2) (push (list *proc* type first end) locks))
          ;; Coalesce same-owner, same-type adjacent intervals.
          (let ((merged nil))
            (dolist (lock (sort locks #'< :key #'third))
              (let ((previous (find-if (lambda (item)
                                (and (eq (first item) (first lock))
                                     (= (second item) (second lock))
                                     (<= (third lock) (fourth item)))) merged)))
                (if previous (setf (fourth previous) (max (fourth previous) (fourth lock)))
                    (push lock merged))))
            (if merged (setf (gethash key *record-locks*) merged)
                (remhash key *record-locks*))))
        (changed)
        nil))))
