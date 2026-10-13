(in-package #:finch/bsd)

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

(defun host-errno (code)
  (or (loop :for (name . nil) :in +errno+
            :for host := (find-symbol (symbol-name name) :sb-posix)
            :when (and host (boundp host) (= (symbol-value host) code))
              :return name)
      :eio))

(defmacro host (&body body)
  `(handler-case (progn ,@body)
     (sb-posix:syscall-error (e) (fail (host-errno (sb-posix:syscall-errno e))))))

(defun host-flags (flags)
  (logior (ecase (logand flags 3) (0 sb-posix:o-rdonly) (1 sb-posix:o-wronly) (2 sb-posix:o-rdwr))
          (loop :for (darwin . linux) :in (list (cons +o-append+ sb-posix:o-append)
                                                (cons +o-creat+ sb-posix:o-creat)
                                                (cons +o-trunc+ sb-posix:o-trunc)
                                                (cons +o-excl+ sb-posix:o-excl)
                                                (cons +o-nonblock+ sb-posix:o-nonblock)
                                                (cons +o-directory+ sb-posix:o-directory))
                :when (logtest flags darwin) :sum linux)))

(defclass vnode (file)
  ((fd :initarg :fd :reader host-fd)))

(defmethod file-read ((file vnode) count)
  (let ((buffer (make-array count :element-type '(unsigned-byte 8))))
    (let ((n (host (sb-sys:with-pinned-objects (buffer)
                     (sb-posix:read (host-fd file) (sb-sys:vector-sap buffer) count)))))
      (subseq buffer 0 n))))

(defmethod file-write ((file vnode) octets)
  (let ((buffer (coerce octets '(simple-array (unsigned-byte 8) (*)))))
    (host (sb-sys:with-pinned-objects (buffer)
            (sb-posix:write (host-fd file) (sb-sys:vector-sap buffer) (length buffer))))))

(defmethod file-close ((file vnode))
  (host (sb-posix:close (host-fd file))))

(defun path (name)
  (if (and (plusp (length name)) (char= (char name 0) #\/))
      name
      (format nil "~a/~a" (string-right-trim "/" (proc-cwd *proc*)) name)))

(defun open (name flags &optional (mode #o644))
  (syscall
    (fd-alloc (make-instance 'vnode :fd (host (sb-posix:open (path name) (host-flags flags) mode))
                                    :flags (logand flags +o-nonblock+)))))

(defun lseek (fd offset whence)
  (syscall
    (let ((file (fd-file fd)))
      (unless (typep file 'vnode) (fail :espipe))
      (host (sb-posix:lseek (host-fd file) offset
                            (ecase whence (:set sb-posix:seek-set) (:cur sb-posix:seek-cur) (:end sb-posix:seek-end)))))))

(defun stat-plist (stat)
  (list :mode (sb-posix:stat-mode stat) :size (sb-posix:stat-size stat) :nlink (sb-posix:stat-nlink stat)
        :ino (sb-posix:stat-ino stat) :mtime (sb-posix:stat-mtime stat)))

(defun stat (name)
  (syscall (stat-plist (host (sb-posix:stat (path name))))))

(defun lstat (name)
  (syscall (stat-plist (host (sb-posix:lstat (path name))))))

(defun fstat (fd)
  (syscall
    (let ((file (fd-file fd)))
      (if (typep file 'vnode)
          (stat-plist (host (sb-posix:fstat (host-fd file))))
          (list :mode +s-ififo+ :size 0 :nlink 1 :ino 0 :mtime 0)))))

(defun mkdir (name &optional (mode #o755))
  (syscall (host (sb-posix:mkdir (path name) mode)) 0))

(defun rmdir (name)
  (syscall (host (sb-posix:rmdir (path name))) 0))

(defun unlink (name)
  (syscall
    (handler-case (host (sb-posix:unlink (path name)))
      (errno (e) (fail (if (eq (errno-name e) :eisdir) :eperm (errno-name e)))))
    0))

(defun rename (from to)
  (syscall (host (sb-posix:rename (path from) (path to))) 0))

(defun symlink (target name)
  (syscall (host (sb-posix:symlink target (path name))) 0))

(defun readdir (name)
  (syscall
    (let ((dir (host (sb-posix:opendir (path name)))))
      (unwind-protect
           (loop :for entry := (sb-posix:readdir dir)
                 :until (sb-alien:null-alien entry)
                 :for entry-name := (sb-posix:dirent-name entry)
                 :unless (member entry-name '("." "..") :test #'string=)
                   :collect entry-name)
        (sb-posix:closedir dir)))))

(defun chdir (name)
  (syscall
    (let* ((full (path name))
           (mode (sb-posix:stat-mode (host (sb-posix:stat full)))))
      (unless (= (logand mode +s-ifmt+) +s-ifdir+) (fail :enotdir))
      (setf (proc-cwd *proc*)
            (string-right-trim "/" (sb-ext:native-namestring
                                    (truename (sb-ext:parse-native-namestring (format nil "~a/" full))))))
      (when (string= (proc-cwd *proc*) "") (setf (proc-cwd *proc*) "/"))
      0)))

(defun getcwd ()
  (proc-cwd *proc*))
