(in-package #:darterfly/bsd)

(defconstant +o-rdonly+ 0)
(defconstant +o-wronly+ 1)
(defconstant +o-rdwr+ 2)
(defconstant +o-append+ #x8)
(defconstant +o-creat+ #x200)
(defconstant +o-trunc+ #x400)
(defconstant +o-excl+ #x800)
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
        :directory (logtest flags +o-directory+)))

(defclass vnode (file)
  ((fd :initarg :fd :reader vfs-fd)
   (access :initarg :access :initform 2 :reader file-access)
   (device :initarg :device :initform nil :reader device-p)))

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
          (list :mode +s-ififo+ :size 0 :nlink 1 :ino 0 :mtime 0)))))

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
