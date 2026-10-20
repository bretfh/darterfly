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

(defmacro vfs-call ((function &rest arguments))
  ;; Evaluate descriptor/path arguments while BSD still protects them. VFS owns
  ;; filesystem serialization and shared offsets; BSD must not wait on it.
  (let ((values (loop for argument in arguments collect (gensym "ARG"))))
    `(let ,(mapcar #'list values arguments)
       (call-without-bsd (lambda () (vfs (,function ,@values)))))))

(defun locked-vnode-operation (function &rest arguments)
  ;; Raw VNOPs do not acquire the VFS lock themselves.
  (vfs::with-vfs (apply function arguments)))

(defmacro with-vnode-file ((name expression) &body body)
  `(with-bsd
     (let ((,name ,expression))
       (unless (typep ,name 'vnode) (fail :espipe))
       (sb-sys:without-interrupts
         (incf (file-refs ,name))
         (unwind-protect (sb-sys:with-local-interrupts ,@body)
           (when (zerop (decf (file-refs ,name))) (file-close ,name)))))))

(defun vfs-flags (flags)
  (list :access (ecase (logand flags 3) (0 :rdonly) (1 :wronly) (2 :rdwr))
        :creat (logtest flags +o-creat+) :excl (logtest flags +o-excl+) :trunc (logtest flags +o-trunc+)
        :append (logtest flags +o-append+) :nonblock (logtest flags +o-nonblock+)
        :nofollow (logtest flags +o-nofollow+)
        :directory (logtest flags +o-directory+)))

(defclass vnode (file)
  ((fd :initarg :fd :reader vfs-fd)
   (access :initarg :access :initform 2 :reader file-access)
   (device :initarg :device :initform nil :reader device-p)))

(defmethod file-read ((file vnode) count)
  (with-vnode-file (held file)
    (vfs-call (vfs:vfs-read (vfs-fd held) count))))

(defmethod file-write ((file vnode) octets)
  (with-vnode-file (held file)
    (vfs-call (vfs:vfs-write (vfs-fd held) octets))))

(defmethod file-close ((file vnode))
  ;; Only the short descriptor-table lock, never the filesystem lock.
  (vfs (vfs:vfs-close (vfs-fd file))))

(defun install-vnode (fd flags)
  (let ((installed nil))
    (unwind-protect
         (let ((device (= (mode-type (vfs:vattr-mode (vfs-call (vfs:vfs-fstat fd)))) +s-ifchr+)))
           (when (or (proc-closing *proc*) (eq (proc-state *proc*) :zombie))
             (fail :eintr))
           (prog1 (fd-alloc (make-instance 'vnode :fd fd :access (logand flags 3)
                                                :device device :flags (logand flags +o-nonblock+)))
             (setf installed t)))
      (unless installed (vfs:vfs-close fd)))))

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
    (install-vnode (vfs-call (vfs:vfs-open (path name) (vfs-flags flags) mode)) flags)))

(defun lseek (fd offset whence)
  (syscall
    (with-vnode-file (file (fd-file fd))
      (vfs-call (vfs:vfs-lseek (vfs-fd file) offset (ecase whence (:set 0) (:cur 1) (:end 2)))))))

(defun stat-plist (attr id)
  (list :mode (vfs:vattr-mode attr) :size (vfs:vattr-size attr) :nlink (vfs:vattr-nlink attr)
        :ino id :mtime (floor (vfs:vattr-mtime attr) 1000000000)))

(defun stat-path (name follow)
  (let ((v (vfs-call (vfs:namei (path name) :follow follow))))
    (stat-plist (vfs-call (locked-vnode-operation #'vfs:vnop-getattr v)) (vfs:vnode-id v))))

(defun stat (name) (syscall (stat-path name t)))
(defun lstat (name) (syscall (stat-path name nil)))

(defun fstat (fd)
  (syscall
    (let ((file (fd-file fd)))
      (if (typep file 'vnode)
          (with-vnode-file (held file)
            (let ((v (vfs-call (vfs:fd-vnode (vfs-fd held)))))
              (stat-plist (vfs-call (locked-vnode-operation #'vfs:vnop-getattr v)) (vfs:vnode-id v))))
          (list :mode (if (typep file 'socket) #o140000 +s-ififo+) :size 0 :nlink 1 :ino 0 :mtime 0)))))

(defun mkdir (name &optional (mode #o755))
  (syscall (vfs-call (vfs:vfs-mkdir (path name) mode)) 0))

(defun rmdir (name)
  (syscall (vfs-call (vfs:vfs-remove (path name) t)) 0))

(defun unlink (name)
  (syscall
    (handler-case (vfs-call (vfs:vfs-remove (path name) nil))
      (errno (e) (fail (if (eq (errno-name e) :eisdir) :eperm (errno-name e)))))
    0))

(defun rename (from to)
  (syscall (vfs-call (vfs:vfs-rename (path from) (path to))) 0))

(defun symlink (target name)
  (syscall (vfs-call (vfs:vfs-symlink target (path name))) 0))

(defun directory-vnode (name)
  (let ((v (vfs-call (vfs:namei (path name)))))
    (unless (eq (vfs:vnode-type v) :vdir) (fail :enotdir))
    v))

(defun readdir (name)
  (syscall (mapcar #'car (vfs-call (locked-vnode-operation #'vfs:vnop-readdir (directory-vnode name))))))

(defun chdir (name)
  (syscall
    (directory-vnode name)
    (setf (proc-cwd *proc*) (unroot (vfs-call (vfs:vfs-realpath (path name)))))
    0))

(defun chroot (name)
  (syscall
    (directory-vnode name)
    (setf (proc-root *proc*) (vfs-call (vfs:vfs-realpath (path name)))
          (proc-cwd *proc*) "/")
    0))

(defun getcwd ()
  (proc-cwd *proc*))
