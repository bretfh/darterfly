(in-package #:darterfly/bsd)

(defconstant +af-local+ 1)
(defconstant +af-inet+ 2)
(defconstant +af-inet6+ 30)
(defconstant +sock-stream+ 1)
(defconstant +sock-dgram+ 2)

(defclass socket (file)
  ((family :initarg :family :initform +af-inet+ :reader socket-family)
   (connect-pending :initform nil :accessor socket-connect-pending)
   (type :initarg :type :reader socket-type)
   (port :initform nil :accessor socket-port)
   (pcb :initform nil :accessor socket-pcb)
   (peer :initform nil :accessor socket-peer)
   (pending :initform nil :accessor socket-pending)))

(defgeneric internet-socket-p (socket)
  (:method ((socket socket)) t))

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
    (string (darterfly/net:ip-address address))
    (integer address)
    (vector address)))

(defun net-wait (file thunk)
  (loop
    (let ((result (without-bsd
                    (handler-case (funcall thunk (if (nonblocking-p file) 0 0.1))
                      (darterfly/net:net-error (e) (list :fail (darterfly/net:net-errno e)))))))
      (cond ((and (consp result) (eq (first result) :fail)) (fail (second result)))
            ((not (eq result :again)) (return result))
            ((nonblocking-p file) (fail :eagain))
            ((and (plusp (deliverable *proc*)) (deliver *proc*)) (fail :eintr))))))

(defun socket (domain type &optional (protocol 0))
  (syscall
    (when (= domain +af-local+)
      (return-from socket (fd-alloc (new-local-socket type protocol))))
    (unless (member domain (list +af-inet+ +af-inet6+)) (fail :eafnosupport))
    (unless (member type (list +sock-stream+ +sock-dgram+)) (fail :eprotonosupport))
    (fd-alloc (make-instance 'socket :type type :family domain :flags 2))))

(defun bind (fd address &optional port)
  (syscall
    (let ((s (fd-socket fd)))
      (unless (internet-socket-p s) (return-from bind (local-bind s address)))
      (when (socket-port s) (fail :einval))
      (setf (socket-port s) port)
      (when (= (socket-type s) +sock-dgram+)
        (setf (socket-pcb s) (darterfly/net:udp-bind port)))
      0)))

(defun listen (fd &optional (backlog 5))
  (syscall
    (let ((s (fd-socket fd)))
      (unless (internet-socket-p s) (return-from listen (local-listen s backlog)))
      (unless (= (socket-type s) +sock-stream+) (fail :eopnotsupp))
      (unless (socket-port s) (fail :edestaddrreq))
      (setf (socket-pcb s) (darterfly/net:tcp-listen (socket-port s)))
      0)))

(defun accept (fd)
  (syscall
    (let ((s (fd-socket fd)))
      (unless (internet-socket-p s) (return-from accept (local-accept s)))
      (unless (typep (socket-pcb s) 'darterfly/net:listener) (fail :einval))
      (let* ((c (net-wait s (lambda (timeout) (or (darterfly/net:tcp-accept (socket-pcb s) :timeout timeout) :again))))
             (new (make-instance 'socket :type +sock-stream+ :family (socket-family s) :flags 2)))
        (setf (socket-pcb new) c (socket-port new) (socket-port s))
        (multiple-value-bind (address port) (darterfly/net:tcp-peer c)
          (values (fd-alloc new) address port))))))

(defun connect (fd address &optional port)
  (syscall
    (let ((s (fd-socket fd)))
      (unless (internet-socket-p s) (return-from connect (local-connect s address)))
      (if (= (socket-type s) +sock-stream+)
          (progn
            (when (socket-pcb s)
              (fail (if (socket-connect-pending s) :ealready :eisconn)))
            (if (nonblocking-p s)
                (progn
                  (setf (socket-pcb s)
                        (without-bsd
                          (darterfly/net:tcp-connect (ip-of address) port :wait nil))
                        (socket-connect-pending s) t)
                  (fail :einprogress))
                (setf (socket-pcb s)
                      (net-wait s (lambda (timeout)
                                    (declare (ignore timeout))
                                    (darterfly/net:tcp-connect (ip-of address) port))))))
          (setf (socket-peer s) (list (ip-of address) port)))
      0)))

(defun dgram-port (s)
  (or (socket-pcb s)
      (setf (socket-port s) (+ 49152 (random 16384))
            (socket-pcb s) (darterfly/net:udp-bind (socket-port s)))))

(defun sendto (fd octets address port)
  (syscall
    (let ((s (fd-socket fd)))
      (unless (= (socket-type s) +sock-dgram+) (fail :eisconn))
      (dgram-port s)
      (net-wait s (lambda (timeout) (declare (ignore timeout)) (darterfly/net:udp-send (ip-of address) (socket-port s) port octets)))
      (length octets))))

(defun recvfrom (fd count)
  (syscall
    (let ((s (fd-socket fd)))
      (unless (= (socket-type s) +sock-dgram+) (fail :eopnotsupp))
      (let ((port (dgram-port s)))
        (destructuring-bind (data address from)
            (net-wait s (lambda (timeout)
                          (multiple-value-bind (data address from) (darterfly/net:udp-receive port :timeout timeout)
                            (if data (list data address from) :again))))
          (values (subseq data 0 (min count (length data))) (darterfly/net:address-string address) from))))))

(defun connection (s)
  (let ((c (socket-pcb s)))
    (unless (typep c 'darterfly/net:connection) (fail :enotconn))
    c))

(defmethod file-read ((s socket) count)
  (if (= (socket-type s) +sock-dgram+)
      (let ((port (dgram-port s)))
        (net-wait s (lambda (timeout) (or (darterfly/net:udp-receive port :timeout timeout) :again))))
      (let ((c (connection s)))
        (unless (socket-pending s)
          (setf (socket-pending s)
                (net-wait s (lambda (timeout)
                              (let ((data (darterfly/net:tcp-receive c :timeout timeout)))
                                (cond ((null data) (if (darterfly/net:tcp-reset-p c) (list :fail :econnreset) #()))
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
        (net-wait s (lambda (timeout) (declare (ignore timeout)) (darterfly/net:udp-send address (socket-port s) port octets)))
        (length octets))
      (let ((c (connection s)))
        (net-wait s (lambda (timeout) (declare (ignore timeout)) (darterfly/net:tcp-send c octets))))))

(defmethod file-close ((s socket))
  (let ((pcb (socket-pcb s)))
    (without-bsd
      (typecase pcb
        (darterfly/net:connection (ignore-errors (darterfly/net:tcp-close pcb)))
        (darterfly/net:listener (darterfly/net:tcp-unlisten pcb))
        (darterfly/net:port (darterfly/net:udp-close pcb))))))

(defun send (fd octets) (write fd octets))
(defun recv (fd count) (read fd count))

(defun libsa-socket-option (operation fd level option record)
  (let* ((socket (fd-socket fd))
         (sap (sb-sys:int-sap record))
         (length (sb-sys:sap-ref-64 sap 0))
         (setting (eq operation :setsockopt))
         (value (when (>= length 4) (sb-sys:signed-sap-ref-32 sap 8)))
         (pcb (socket-pcb socket)))
    (when (> length 16) (fail :einval))
    (if setting
        ;; TCP output currently sends immediately; disabling Nagle is supported.
        ;; Unsupported options must not silently succeed.
        (unless (and (= level 6) (= option 1) value (plusp value)
                     (internet-socket-p socket) (= (socket-type socket) +sock-stream+))
          (fail :enoprotoopt))
        (let ((result
                (cond ((= level 1)
                       (case option
                         (3 (socket-type socket))
                         (4 (cond
                              ((and (typep pcb 'darterfly/net:connection)
                                    (darterfly/net:tcp-reset-p pcb))
                               (prog1 (vfs:errno-code
                                        (if (socket-connect-pending socket)
                                            :econnrefused :econnreset))
                                 (setf (socket-connect-pending socket) nil)))
                              (t
                               (when (and (typep pcb 'darterfly/net:connection)
                                          (eq (darterfly/net::tcp-state pcb) :established))
                                 (setf (socket-connect-pending socket) nil))
                               0)))
                         (30 (if (if (internet-socket-p socket)
                                     (typep pcb 'darterfly/net:listener)
                                     (eq (local-state socket) :listening))
                                 1 0))
                         (7 darterfly/net::+sndbuf+)
                         (8 darterfly/net::+rcvbuf+)
                         ((2 6 9 10) 0)
                         (t (fail :enoprotoopt))))
                      ((and (= level 6) (= option 1)) 1)
                      (t (fail :enoprotoopt)))))
          (unless (>= length 4) (fail :einval))
          (setf (sb-sys:sap-ref-64 sap 0) 4
                (sb-sys:signed-sap-ref-32 sap 8) result)))
    0))
