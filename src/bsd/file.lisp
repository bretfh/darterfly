(in-package #:darterfly/bsd)

(defconstant +o-nonblock+ #x4)
(defconstant +f-getfl+ 3)
(defconstant +f-setfl+ 4)
(defconstant +pipe-size+ 65536)
(defconstant +pipe-buf+ 512)

(defclass file ()
  ((refs :initform 1 :accessor file-refs)
   (flags :initarg :flags :initform 0 :accessor file-flags)))

(defgeneric file-read (file count))
(defgeneric file-write (file octets))
(defgeneric file-close (file))
(defgeneric file-access (file)
  (:method ((file file)) 2))

(defmethod file-close ((file file)))

(defun nonblocking-p (file)
  (logtest (file-flags file) +o-nonblock+))

(defun fd-file (fd)
  (let ((fds (proc-fds *proc*)))
    (or (and (integerp fd) (< -1 fd (length fds)) (car (aref fds fd)))
        (fail :ebadf))))

(defun fd-alloc (file &optional (from 0))
  (let ((fds (proc-fds *proc*)))
    (let ((fd (or (position nil fds :start (min from (length fds)))
                  (progn (loop :while (< (length fds) from) :do (vector-push-extend nil fds))
                         (vector-push-extend nil fds)
                         (1- (length fds))))))
      (setf (aref fds fd) (cons file nil))
      fd)))

(defun release-fd (proc fd)
  (let ((file (car (aref (proc-fds proc) fd))))
    (setf (aref (proc-fds proc) fd) nil)
    (when (zerop (decf (file-refs file)))
      (file-close file))
    (changed)))

(defun close (fd)
  (syscall
    (fd-file fd)
    (release-fd *proc* fd)
    0))

(defun dup (fd)
  (syscall
    (let ((file (fd-file fd)))
      (incf (file-refs file))
      (fd-alloc file))))

(defun dup2 (fd new)
  (unless (<= 0 new 4095) (fail :ebadf))
  (syscall
    (let ((file (fd-file fd)))
      (unless (= fd new)
        (let ((fds (proc-fds *proc*)))
          (when (and (< new (length fds)) (aref fds new))
            (release-fd *proc* new))
          (loop :while (<= (length fds) new) :do (vector-push-extend nil fds))
          (incf (file-refs file))
          (setf (aref fds new) (cons file nil))))
      new)))

(defun fcntl (fd command &optional arg)
  (syscall
    (let ((file (fd-file fd)))
      (cond ((= command +f-getfl+) (file-flags file))
            ((= command +f-setfl+) (setf (file-flags file) arg) 0)
            (t (fail :einval))))))

(defun read (fd count)
  (syscall (file-read (fd-file fd) count)))

(defun write (fd octets)
  (syscall (file-write (fd-file fd) octets)))

(defclass pipe-buffer ()
  ((octets :initform (make-array 0 :element-type '(unsigned-byte 8) :adjustable t :fill-pointer 0)
           :accessor octets)
   (readers :initform 1 :accessor readers)
   (writers :initform 1 :accessor writers)))

(defclass pipe-end (file)
  ((buffer :initarg :buffer :reader buffer)))

(defclass read-end (pipe-end) ())
(defclass write-end (pipe-end) ())

(defmethod file-access ((file read-end)) 0)
(defmethod file-access ((file write-end)) 1)

(defun pipe ()
  (syscall
    (let ((buffer (make-instance 'pipe-buffer)))
      (values (fd-alloc (make-instance 'read-end :buffer buffer))
              (fd-alloc (make-instance 'write-end :buffer buffer))))))

(defmethod file-close ((file read-end))
  (decf (readers (buffer file))))

(defmethod file-close ((file write-end))
  (decf (writers (buffer file))))

(defmethod file-read ((file write-end) count)
  (fail :ebadf))

(defmethod file-write ((file read-end) octets)
  (fail :ebadf))

(defmethod file-read ((file read-end) count)
  (let ((buffer (buffer file)))
    (sleep-until (lambda ()
                   (or (plusp (length (octets buffer)))
                       (zerop (writers buffer))
                       (and (nonblocking-p file) (fail :eagain)))))
    (let* ((data (octets buffer))
           (n (min count (length data)))
           (taken (subseq data 0 n)))
      (replace data data :start2 n)
      (setf (fill-pointer data) (- (length data) n))
      (changed)
      taken)))

(defun broken-pipe ()
  (post *proc* (signo :sigpipe))
  (deliver *proc*)
  (fail :epipe))

(defmethod file-write ((file write-end) octets)
  (let ((buffer (buffer file))
        (written 0)
        (total (length octets)))
    (when (zerop (readers buffer)) (broken-pipe))
    (loop :while (< written total)
          :do (let ((room (- +pipe-size+ (length (octets buffer))))
                    (left (- total written)))
                (cond ((zerop (readers buffer))
                       (if (zerop written) (broken-pipe) (return)))
                      ((and (plusp room) (or (> left +pipe-buf+) (>= room left)))
                       (let ((n (min room left)))
                         (loop :for i :from written :below (+ written n)
                               :do (vector-push-extend (aref octets i) (octets buffer)))
                         (incf written n)
                         (changed)))
                      ((nonblocking-p file)
                       (if (zerop written) (fail :eagain) (return)))
                      (t (sleep-until (lambda ()
                                        (or (zerop (readers buffer))
                                            (< (length (octets buffer)) +pipe-size+))))))))
    written))
