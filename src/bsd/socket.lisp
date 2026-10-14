(in-package #:finch/bsd)

(defconstant +af-inet+ 2)
(defconstant +af-inet6+ 30)
(defconstant +sock-stream+ 1)
(defconstant +sock-dgram+ 2)

(defclass socket (file)
  ((type :initarg :type :reader socket-type)
   (port :initform nil :accessor socket-port)
   (pcb :initform nil :accessor socket-pcb)
   (peer :initform nil :accessor socket-peer)
   (pending :initform nil :accessor socket-pending)))

(defmacro without-bsd (&body body)
  `(if (sb-thread:holding-mutex-p *bsd*)
       (progn (sb-thread:release-mutex *bsd*)
              (unwind-protect (progn ,@body) (sb-thread:grab-mutex *bsd*)))
       (progn ,@body)))

(defun fd-socket (fd)
  (let ((file (fd-file fd)))
    (unless (typep file 'socket) (fail :enotsock))
    file))

(defun ip-of (address)
  (etypecase address
    (string (finch/net:ip-address address))
    (integer address)))

(defun net-wait (file thunk)
  (loop
    (let ((result (without-bsd
                    (handler-case (funcall thunk (if (nonblocking-p file) 0 0.1))
                      (finch/net:net-error (e) (list :fail (finch/net:net-errno e)))))))
      (cond ((and (consp result) (eq (first result) :fail)) (fail (second result)))
            ((not (eq result :again)) (return result))
            ((nonblocking-p file) (fail :eagain))
            ((and (plusp (deliverable *proc*)) (deliver *proc*)) (fail :eintr))))))

(defun socket (domain type &optional (protocol 0))
  (declare (ignore protocol))
  (syscall
    (unless (member domain (list +af-inet+ +af-inet6+)) (fail :eafnosupport))
    (unless (member type (list +sock-stream+ +sock-dgram+)) (fail :eprotonosupport))
    (fd-alloc (make-instance 'socket :type type :flags 2))))

(defun bind (fd address port)
  (declare (ignore address))
  (syscall
    (let ((s (fd-socket fd)))
      (when (socket-port s) (fail :einval))
      (setf (socket-port s) port)
      (when (= (socket-type s) +sock-dgram+)
        (setf (socket-pcb s) (finch/net:udp-bind port)))
      0)))

(defun listen (fd &optional (backlog 5))
  (declare (ignore backlog))
  (syscall
    (let ((s (fd-socket fd)))
      (unless (= (socket-type s) +sock-stream+) (fail :eopnotsupp))
      (unless (socket-port s) (fail :edestaddrreq))
      (setf (socket-pcb s) (finch/net:tcp-listen (socket-port s)))
      0)))

(defun accept (fd)
  (syscall
    (let ((s (fd-socket fd)))
      (unless (typep (socket-pcb s) 'finch/net:listener) (fail :einval))
      (let* ((c (net-wait s (lambda (timeout) (or (finch/net:tcp-accept (socket-pcb s) :timeout timeout) :again))))
             (new (make-instance 'socket :type +sock-stream+ :flags 2)))
        (setf (socket-pcb new) c (socket-port new) (socket-port s))
        (multiple-value-bind (address port) (finch/net:tcp-peer c)
          (values (fd-alloc new) address port))))))

(defun connect (fd address port)
  (syscall
    (let ((s (fd-socket fd)))
      (if (= (socket-type s) +sock-stream+)
          (progn
            (when (socket-pcb s) (fail :eisconn))
            (setf (socket-pcb s) (net-wait s (lambda (timeout) (declare (ignore timeout)) (finch/net:tcp-connect (ip-of address) port)))))
          (setf (socket-peer s) (list (ip-of address) port)))
      0)))

(defun dgram-port (s)
  (or (socket-pcb s)
      (setf (socket-port s) (+ 49152 (random 16384))
            (socket-pcb s) (finch/net:udp-bind (socket-port s)))))

(defun sendto (fd octets address port)
  (syscall
    (let ((s (fd-socket fd)))
      (unless (= (socket-type s) +sock-dgram+) (fail :eisconn))
      (dgram-port s)
      (net-wait s (lambda (timeout) (declare (ignore timeout)) (finch/net:udp-send (ip-of address) (socket-port s) port octets)))
      (length octets))))

(defun recvfrom (fd count)
  (syscall
    (let ((s (fd-socket fd)))
      (unless (= (socket-type s) +sock-dgram+) (fail :eopnotsupp))
      (let ((port (dgram-port s)))
        (destructuring-bind (data address from)
            (net-wait s (lambda (timeout)
                          (multiple-value-bind (data address from) (finch/net:udp-receive port :timeout timeout)
                            (if data (list data address from) :again))))
          (values (subseq data 0 (min count (length data))) (finch/net:address-string address) from))))))

(defun connection (s)
  (let ((c (socket-pcb s)))
    (unless (typep c 'finch/net:connection) (fail :enotconn))
    c))

(defmethod file-read ((s socket) count)
  (if (= (socket-type s) +sock-dgram+)
      (let ((port (dgram-port s)))
        (net-wait s (lambda (timeout) (or (finch/net:udp-receive port :timeout timeout) :again))))
      (let ((c (connection s)))
        (unless (socket-pending s)
          (setf (socket-pending s)
                (net-wait s (lambda (timeout)
                              (let ((data (finch/net:tcp-receive c :timeout timeout)))
                                (cond ((null data) (if (finch/net:tcp-reset-p c) (list :fail :econnreset) #()))
                                      ((zerop (length data)) :again)
                                      (t data)))))))
        (let* ((data (socket-pending s))
               (n (min count (length data))))
          (setf (socket-pending s) (when (< n (length data)) (subseq data n)))
          (subseq data 0 n)))))

(defmethod file-write ((s socket) octets)
  (if (= (socket-type s) +sock-dgram+)
      (destructuring-bind (&optional address port) (socket-peer s)
        (unless address (fail :edestaddrreq))
        (dgram-port s)
        (net-wait s (lambda (timeout) (declare (ignore timeout)) (finch/net:udp-send address (socket-port s) port octets)))
        (length octets))
      (let ((c (connection s)))
        (net-wait s (lambda (timeout) (declare (ignore timeout)) (finch/net:tcp-send c octets))))))

(defmethod file-close ((s socket))
  (let ((pcb (socket-pcb s)))
    (without-bsd
      (typecase pcb
        (finch/net:connection (ignore-errors (finch/net:tcp-close pcb)))
        (finch/net:listener (finch/net:tcp-unlisten pcb))
        (finch/net:port (finch/net:udp-close pcb))))))

(defun send (fd octets) (write fd octets))
(defun recv (fd count) (read fd count))
