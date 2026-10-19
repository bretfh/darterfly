(in-package #:darterfly/bsd)

;; Linux poll bits are also used by libsa's pollfd ABI.
(defgeneric file-poll (file)
  (:method ((file file)) #x8)) ; unsupported descriptor: POLLERR, never fake ready

(defmethod file-poll ((file read-end))
  (logior (if (plusp (length (octets (buffer file)))) 1 0)
          (if (zerop (writers (buffer file))) #x10 0)))

(defmethod file-poll ((file write-end))
  (logior (if (<= (length (octets (buffer file))) (- +pipe-size+ +pipe-buf+)) 4 0)
          (if (zerop (readers (buffer file))) #x8 0)))

(defmethod file-poll ((s local-socket))
  (cond ((eq (local-state s) :listening) (if (local-queue s) 1 0))
        ((null (local-input s)) #x10)
        (t
         (let* ((in (buffer (local-input s))) (out (buffer (local-output s)))
                (eof (or (local-read-shut s) (zerop (writers in))))
                (broken (zerop (readers out))))
           (logior
            (if (or eof (local-queued-p s)) 1 0)
            (if (or (local-write-shut s) broken
                    (and (plusp (local-room s))
                         (< (length (buffer-packets out)) 256))) 4 0)
            (if broken #x8 0)
            (if (and eof (or (local-write-shut s) broken)) #x10 0))))))

(defun console-ready ()
  ;; Query the kernel directly, not libc poll (which calls this service).
  (let ((fds (make-array 16 :element-type '(unsigned-byte 8) :initial-element 0)))
    (setf (aref fds 4) 1 (aref fds 8) 1 (aref fds 12) 4)
    (sb-sys:with-pinned-objects (fds)
      (let ((r (sb-alien:alien-funcall
                (sb-alien:extern-alien "__syscall"
                  (function sb-alien:long sb-alien:long sb-alien:long
                            sb-alien:long sb-alien:long sb-alien:long
                            sb-alien:long sb-alien:long))
                230 (sb-sys:sap-int (sb-sys:vector-sap fds)) 2 0 0 0 0)))
        (if (minusp r) #x8 (logior (aref fds 6) (aref fds 14)))))))

(defmethod file-poll ((file vnode))
  (vfs
    (let ((node (vfs:fd-vnode (vfs-fd file))))
      (case (vfs:vnode-type node)
        ((:vreg :vdir) 5)
        (:vchr (if (typep node 'vfs::dev-node)
                   (case (vfs::node-device node)
                     ((:null :random) 5)
                     (:console (console-ready))
                     (t #x8))
                   #x8))
        (t #x8)))))

(defmethod file-poll ((s socket))
  (let ((pcb (socket-pcb s)))
    (typecase pcb
      (darterfly/net:listener
       (sb-thread:with-recursive-lock (darterfly/net::*tcp-lock*)
         (if (darterfly/net::listener-pending pcb) 1 0)))
      (darterfly/net:connection
       (sb-thread:with-recursive-lock (darterfly/net::*tcp-lock*)
         (logior
          (if (or (socket-pending s)
                  (plusp (length (darterfly/net::tcp-received pcb)))
                  (darterfly/net::tcp-eof pcb) (darterfly/net::tcp-reset pcb)) 1 0)
          (if (and (member (darterfly/net::tcp-state pcb) '(:established :close-wait))
                   (< (darterfly/net::unsent pcb) darterfly/net::+sndbuf+)) 4 0)
          (if (darterfly/net::tcp-reset pcb) #x18 0))))
      (darterfly/net:port
       (sb-thread:with-mutex ((darterfly/net::port-lock pcb))
         (logior 4 (if (darterfly/net::port-queue pcb) 1 0))))
      (t (if (= (socket-type s) +sock-dgram+) 4 #x10)))))

(defun poll-fds (entries timeout)
  "ENTRIES are (fd events) pairs; return one revents mask per entry.
TIMEOUT is milliseconds, negative for no deadline. BSD queue changes wake
immediately. Console and network queues are sampled at most 10ms apart."
  (syscall
    (let ((deadline (unless (minusp timeout)
                      (+ (get-internal-real-time)
                         (ceiling (* timeout internal-time-units-per-second) 1000)))))
      (loop
        (when (or (eq (proc-state *proc*) :zombie)
                  (proc-native-result *proc*)) (fail :eintr))
        (let ((results
                (loop :for (fd events) :in entries
                      :collect
                      (cond ((minusp fd) 0)
                            ((or (>= fd (length (proc-fds *proc*)))
                                 (null (aref (proc-fds *proc*) fd))) #x20)
                            (t (logand (file-poll (fd-file fd))
                                       (logior events #x38)))))))
          (when (or (some #'plusp results)
                    (and deadline (>= (get-internal-real-time) deadline)))
            (return results)))
        (when (and (plusp (deliverable *proc*)) (deliver *proc*)) (fail :eintr))
        (let ((wait (if deadline
                        (min 0.01 (max 0 (/ (- deadline (get-internal-real-time))
                                           internal-time-units-per-second)))
                        0.01)))
          (unwind-protect
               (sb-thread:condition-wait *changed* *bsd* :timeout wait)
            (unless (sb-thread:holding-mutex-p *bsd*)
              (sb-thread:grab-mutex *bsd*))))))))

(defun libsa-poll (address count timeout)
  ;; This also bounds the request and reply in the isolated-world bridge.
  (when (> count 256) (fail :einval))
  (when (and (plusp count) (zerop address)) (fail :efault))
  (let* ((sap (sb-sys:int-sap address))
         (entries (loop :for i :below count :for at := (* i 8)
                        :collect (list (sb-sys:signed-sap-ref-32 sap at)
                                       (sb-sys:sap-ref-16 sap (+ at 4)))))
         (timeout (if (logbitp 31 timeout)
                      (- (ldb (byte 32 0) timeout) (ash 1 32)) timeout))
         (results (poll-fds entries timeout)))
    (loop :for events :in results :for i :from 0
          :do (setf (sb-sys:sap-ref-16 sap (+ (* i 8) 6)) events))
    (count-if #'plusp results)))
