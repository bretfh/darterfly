(in-package #:darterfly/vfs)

(defclass host-node (vnode)
  ((path :initarg :path :reader host-path)))

(defun host-errno (code)
  (or (loop :for (name . nil) :in +errno+
            :for host := (find-symbol (symbol-name name) :sb-posix)
            :when (and host (boundp host) (= (symbol-value host) code))
              :return name)
      :eio))

(defmacro host (&body body)
  `(handler-case (progn ,@body)
     (sb-posix:syscall-error (e) (fail (host-errno (sb-posix:syscall-errno e))))))

(defun host-type (mode)
  (case (logand mode #o170000)
    (#o040000 :vdir) (#o120000 :vlnk) (#o020000 :vchr) (#o010000 :vfifo) (t :vreg)))

(defun child-path (dir name)
  (format nil "~a/~a" (string-right-trim "/" (host-path dir)) name))

(defun host-child (dir name)
  (let ((path (child-path dir name)))
    (handler-case (let ((stat (sb-posix:lstat path)))
                    (make-instance 'host-node :path path :type (host-type (sb-posix:stat-mode stat))
                                              :id (sb-posix:stat-ino stat)))
      (sb-posix:syscall-error (e)
        (if (= (sb-posix:syscall-errno e) sb-posix:enoent) nil (fail (host-errno (sb-posix:syscall-errno e))))))))

(defun make-host-root (&optional (path "/"))
  (make-instance 'host-node :path path :type :vdir))

(defmethod vnop-lookup ((dir host-node) name) (host-child dir name))

(defmethod vnop-readdir ((dir host-node))
  (let ((d (host (sb-posix:opendir (host-path dir)))))
    (unwind-protect
         (loop :for entry := (sb-posix:readdir d)
               :until (sb-alien:null-alien entry)
               :for name := (sb-posix:dirent-name entry)
               :for child := (unless (member name '("." "..") :test #'string=) (host-child dir name))
               :when child :collect (cons name child))
      (sb-posix:closedir d))))

(defmacro with-host-fd ((fd node flags) &body body)
  `(let ((,fd (host (sb-posix:open (host-path ,node) ,flags))))
     (unwind-protect (progn ,@body) (sb-posix:close ,fd))))

(defmethod vnop-read ((n host-node) offset count)
  (let ((buffer (make-array count :element-type '(unsigned-byte 8))))
    (with-host-fd (fd n sb-posix:o-rdonly)
      (when (eq (vnode-type n) :vreg) (host (sb-posix:lseek fd offset sb-posix:seek-set)))
      (subseq buffer 0 (host (sb-sys:with-pinned-objects (buffer) (sb-posix:read fd (sb-sys:vector-sap buffer) count)))))))

(defmethod vnop-write ((n host-node) offset octets)
  (let ((buffer (coerce octets '(simple-array (unsigned-byte 8) (*)))))
    (with-host-fd (fd n sb-posix:o-wronly)
      (when (eq (vnode-type n) :vreg) (host (sb-posix:lseek fd offset sb-posix:seek-set)))
      (host (sb-sys:with-pinned-objects (buffer) (sb-posix:write fd (sb-sys:vector-sap buffer) (length buffer)))))))

(defmethod vnop-getattr ((n host-node))
  (let ((stat (host (sb-posix:lstat (host-path n)))))
    (make-vattr :mode (sb-posix:stat-mode stat) :uid (sb-posix:stat-uid stat) :gid (sb-posix:stat-gid stat)
                :size (sb-posix:stat-size stat) :nlink (sb-posix:stat-nlink stat)
                :mtime (* 1000000000 (sb-posix:stat-mtime stat)) :rdev (sb-posix:stat-rdev stat))))

(defmethod vnop-readlink ((n host-node)) (host (sb-posix:readlink (host-path n))))

(defmethod vnop-create ((dir host-node) name mode)
  (sb-posix:close (host (sb-posix:open (child-path dir name) (logior sb-posix:o-creat sb-posix:o-wronly) mode)))
  (host-child dir name))

(defmethod vnop-mkdir ((dir host-node) name mode)
  (host (sb-posix:mkdir (child-path dir name) mode))
  (host-child dir name))

(defmethod vnop-symlink ((dir host-node) name target)
  (host (sb-posix:symlink target (child-path dir name)))
  (host-child dir name))

(defmethod vnop-remove ((dir host-node) name vnode)
  (declare (ignore name))
  (host (sb-posix:unlink (host-path vnode))))

(defmethod vnop-rmdir ((dir host-node) name vnode)
  (declare (ignore name))
  (host (sb-posix:rmdir (host-path vnode))))

(defmethod vnop-rename ((from-dir host-node) from-name vnode (to-dir host-node) to-name)
  (declare (ignore from-name))
  (host (sb-posix:rename (host-path vnode) (child-path to-dir to-name))))

(defmethod vnop-setattr ((n host-node) &key mode uid gid)
  (when mode (host (sb-posix:chmod (host-path n) (logand mode #o7777))))
  (when (or (and uid (/= uid -1)) (and gid (/= gid -1)))
    (host (sb-posix:lchown (host-path n) (if (and uid (/= uid -1)) uid #xffffffff) (if (and gid (/= gid -1)) gid #xffffffff))))
  0)

(defmethod vnop-truncate ((n host-node) size) (host (sb-posix:truncate (host-path n) size)) 0)
