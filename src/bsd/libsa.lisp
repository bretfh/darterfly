(in-package #:finch/bsd)

(defparameter +libsa-ops+
  #(nil :open :close :read :write :pread :pwrite :lseek :stat :lstat :fstat :readlink :symlink :mkdir :rmdir
    :unlink :rename :chdir :fchdir :getcwd :realpath :chmod :fchmod :chown :fchown :truncate :ftruncate :dup :dup2
    :fcntl :readdir :link :utimes :fsync :umask :pipe))

(defun c-string (address)
  (let* ((sap (sb-sys:int-sap address))
         (n (loop :for i :from 0 :until (zerop (sb-sys:sap-ref-8 sap i)) :finally (return i)))
         (v (make-array n :element-type '(unsigned-byte 8))))
    (sb-sys:with-pinned-objects (v) (sb-kernel:system-area-ub8-copy sap 0 (sb-sys:vector-sap v) 0 n))
    (sb-ext:octets-to-string v :external-format :utf-8)))

(defun put-octets (octets address &optional (limit (length octets)))
  (let ((n (min limit (length octets)))
        (v (coerce octets '(simple-array (unsigned-byte 8) (*)))))
    (sb-sys:with-pinned-objects (v) (sb-kernel:system-area-ub8-copy (sb-sys:vector-sap v) 0 (sb-sys:int-sap address) 0 n))
    n))

(defun get-octets (address n)
  (let ((v (make-array n :element-type '(unsigned-byte 8))))
    (sb-sys:with-pinned-objects (v) (sb-kernel:system-area-ub8-copy (sb-sys:int-sap address) 0 (sb-sys:vector-sap v) 0 n))
    v))

(defun put-string (string address size)
  (let ((octets (sb-ext:string-to-octets string :external-format :utf-8 :null-terminate t)))
    (when (> (length octets) size) (fail :erange))
    (put-octets octets address)
    (1- (length octets))))

(defun signed (n) (if (logbitp 63 n) (- n (ash 1 64)) n))

(defun from-libsa-flags (flags)
  (logior (logand flags 3)
          (if (logtest flags #o100) +o-creat+ 0) (if (logtest flags #o200) +o-excl+ 0)
          (if (logtest flags #o1000) +o-trunc+ 0) (if (logtest flags #o2000) +o-append+ 0)
          (if (logtest flags #o4000) +o-nonblock+ 0) (if (logtest flags #o200000) +o-directory+ 0)))

(defun put-stat (attr id address)
  (let ((sap (sb-sys:int-sap address))
        (mtime (vfs:vattr-mtime attr)))
    (dotimes (i 144) (setf (sb-sys:sap-ref-8 sap i) 0))
    (setf (sb-sys:sap-ref-64 sap 8) id
          (sb-sys:sap-ref-64 sap 16) (vfs:vattr-nlink attr)
          (sb-sys:sap-ref-32 sap 24) (vfs:vattr-mode attr)
          (sb-sys:sap-ref-32 sap 28) (logand (vfs:vattr-uid attr) #xffffffff)
          (sb-sys:sap-ref-32 sap 32) (logand (vfs:vattr-gid attr) #xffffffff)
          (sb-sys:sap-ref-64 sap 40) (vfs:vattr-rdev attr)
          (sb-sys:sap-ref-64 sap 48) (vfs:vattr-size attr)
          (sb-sys:sap-ref-64 sap 56) 4096
          (sb-sys:sap-ref-64 sap 64) (ceiling (vfs:vattr-size attr) 512))
    (loop :for at :in '(72 88 104)
          :do (setf (sb-sys:sap-ref-64 sap at) (floor mtime 1000000000)
                    (sb-sys:sap-ref-64 sap (+ at 8)) (mod mtime 1000000000)))
    0))

(defun put-vnode-stat (vnode address)
  (put-stat (vfs:vnop-getattr vnode) (vfs:vnode-id vnode) address))

(defun put-dirent (name vnode address)
  (let ((sap (sb-sys:int-sap address))
        (octets (sb-ext:string-to-octets name :external-format :utf-8 :null-terminate t)))
    (setf (sb-sys:sap-ref-64 sap 0) (vfs:vnode-id vnode)
          (sb-sys:sap-ref-64 sap 8) 0
          (sb-sys:sap-ref-16 sap 16) 280
          (sb-sys:sap-ref-8 sap 18) (case (vfs:vnode-type vnode) (:vdir 4) (:vreg 8) (:vlnk 10) (:vchr 2) (t 0)))
    (put-octets octets (+ address 19) 256)
    1))

(defun vnode-file (fd)
  (let ((file (fd-file fd)))
    (unless (typep file 'vnode) (fail :espipe))
    file))

(defun fd-vnode (fd) (vfs (vfs:fd-vnode (vfs-fd (vnode-file fd)))))

(defun path-vnode (address &optional (follow t))
  (vfs (vfs:namei (path (c-string address)) :follow follow)))

(defun dup-from (fd from)
  (syscall
    (let ((file (fd-file fd)))
      (incf (file-refs file))
      (fd-alloc file from))))

(defun put-fds (read write address)
  (setf (sb-sys:sap-ref-32 (sb-sys:int-sap address) 0) read
        (sb-sys:sap-ref-32 (sb-sys:int-sap address) 4) write)
  0)

(defun libsa-call (op a b c d)
  (ecase op
    (:open (let ((fd (open (c-string a) (from-libsa-flags b) c)))
             (if (< fd 3) (prog1 (dup-from fd 3) (close fd)) fd)))
    (:close (close a))
    (:read (put-octets (read a c) b))
    (:write (write a (get-octets b c)))
    (:pread (put-octets (vfs (vfs:vfs-read (vfs-fd (vnode-file a)) c (signed d))) b))
    (:pwrite (vfs (vfs:vfs-write (vfs-fd (vnode-file a)) (get-octets b c) (signed d))))
    (:lseek (lseek a (signed b) (ecase c (0 :set) (1 :cur) (2 :end))))
    (:stat (put-vnode-stat (path-vnode a) b))
    (:lstat (put-vnode-stat (path-vnode a nil) b))
    (:fstat (let ((file (fd-file a)))
              (if (typep file 'vnode)
                  (put-vnode-stat (fd-vnode a) b)
                  (put-stat (vfs:make-vattr :mode (logior +s-ififo+ #o600)) 0 b))))
    (:readlink (put-octets (sb-ext:string-to-octets (vfs (vfs:vfs-readlink (path (c-string a)))) :external-format :utf-8) b c))
    (:symlink (symlink (c-string a) (c-string b)))
    (:mkdir (mkdir (c-string a) b))
    (:rmdir (rmdir (c-string a)))
    (:unlink (unlink (c-string a)))
    (:rename (rename (c-string a) (c-string b)))
    (:chdir (chdir (c-string a)))
    (:fchdir (fail :enotsup))
    (:getcwd (put-string (getcwd) a b))
    (:realpath (put-string (unroot (vfs (vfs:vfs-realpath (path (c-string a))))) b c))
    (:chmod (vfs (vfs:vnop-setattr (path-vnode a) :mode b)))
    (:fchmod (vfs (vfs:vnop-setattr (fd-vnode a) :mode b)))
    (:chown (vfs (vfs:vnop-setattr (path-vnode a) :uid (signed b) :gid (signed c))))
    (:fchown (vfs (vfs:vnop-setattr (fd-vnode a) :uid (signed b) :gid (signed c))))
    (:truncate (vfs (vfs:vnop-truncate (path-vnode a) b)) 0)
    (:ftruncate (vfs (vfs:vnop-truncate (fd-vnode a) b)) 0)
    (:dup (dup-from a 3))
    (:dup2 (if (< b 3) (fail :ebadf) (dup2 a b)))
    (:fcntl (let ((file (fd-file a)))
              (case b
                (0 (dup-from a (max c 3)))
                (3 (logior (file-access file) (if (nonblocking-p file) #o4000 0)))
                (4 (setf (file-flags file) (if (logtest c #o4000) +o-nonblock+ 0)) 0)
                (t 0))))
    (:readdir (let ((entry (vfs (vfs:vfs-readdir (vfs-fd (vnode-file a)) b))))
                (if entry (put-dirent (car entry) (cdr entry) c) 0)))
    (:link (fail :enotsup))
    (:utimes (path-vnode a) 0)
    (:fsync (fd-file a) 0)
    (:umask (prog1 vfs:*umask* (setf vfs:*umask* (logand a #o777))))
    (:pipe (multiple-value-bind (read write) (pipe)
             (put-fds read write a)))))

(defun libsa-entry (op a b c d)
  (sb-sys:without-interrupts
    (handler-case (or (let ((*proc* *proc0*)) (libsa-call (aref +libsa-ops+ op) a b c d)) 0)
      (errno (e) (- (vfs:errno-code (errno-name e))))
      (error () (- (vfs:errno-code :eio))))))

(defvar *libsa-entry* nil)

(defun console-fds ()
  (let ((fds (proc-fds *proc0*)))
    (dotimes (fd 3)
      (loop :while (<= (length fds) fd) :do (vector-push-extend nil fds))
      (unless (aref fds fd)
        (setf (aref fds fd) (cons (make-instance 'vnode :fd fd :device t :access 2) nil))))))

(defun libsa-start ()
  (console-fds)
  (setf *libsa-entry* (sb-alien::alien-lambda sb-alien:long ((op sb-alien:long) (a sb-alien:unsigned-long)
                                                             (b sb-alien:unsigned-long) (c sb-alien:unsigned-long)
                                                             (d sb-alien:unsigned-long))
                        (libsa-entry op a b c d)))
  (sb-alien:alien-funcall
   (sb-alien:extern-alien "__libsa_vfs_register" (function sb-alien:void sb-alien:system-area-pointer))
   (sb-alien:alien-sap *libsa-entry*)))
