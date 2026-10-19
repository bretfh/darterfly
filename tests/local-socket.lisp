(in-package #:darterfly/test)

(def-suite local-socket :in host)
(in-suite local-socket)

(defmacro with-local-process (&body body)
  `(let* ((bsd:*proc0* (make-instance 'bsd:proc :pid 0 :task mach:*task*))
          (bsd:*proc* bsd:*proc0*))
     (unwind-protect (progn ,@body)
       (bsd::with-bsd
         (loop :for fd :below (length (bsd::proc-fds bsd:*proc*))
               :when (aref (bsd::proc-fds bsd:*proc*) fd)
                 :do (bsd:close fd))))))

(defun local-errno (function)
  (handler-case (progn (funcall function) nil)
    (bsd:errno (e) (bsd:errno-name e))))

(test local-streams-are-full-duplex
  (with-local-process
    (multiple-value-bind (a b) (bsd:socketpair bsd:+af-local+ bsd:+sock-stream+)
      (is (equalp #() (bsd:read a 0)))
      (is (= 3 (bsd:write a #(1 2 3))))
      (is (= 2 (bsd:write b #(4 5))))
      (is (equalp #(1 2) (bsd:read b 2)))
      (is (equalp #(3) (bsd:read b 20)))
      (is (equalp #(4 5) (bsd:read a 20)))
      (bsd:write a #(6 7))
      (is (= 0 (bsd:shutdown a 1)))
      (is (= 0 (bsd:shutdown a 1)) "shutdown is idempotent")
      (is (equalp #(6 7) (bsd:read b 20)) "queued bytes precede EOF")
      (is (equalp #() (bsd:read b 1)))
      (is (= 1 (bsd:write b #(8))) "the other direction stays open")
      (is (equalp #(8) (bsd:read a 1)))
      (is (eq :epipe (local-errno (lambda () (bsd:write a #(9)))))))))

(test local-streams-close-only-the-last-duplicate
  (with-local-process
    (multiple-value-bind (a b) (bsd:socketpair 1 1)
      (let ((copy (bsd:dup a)))
        (bsd:close a)
        (is (= 1 (bsd:write copy #(9))))
        (is (equalp #(9) (bsd:read b 1)))
        (bsd:close copy)
        (is (equalp #() (bsd:read b 1)))
        (is (eq :epipe (local-errno (lambda () (bsd:write b #(1))))))))))

(test local-streams-bound-buffering
  (with-local-process
    (multiple-value-bind (a b) (bsd:socketpair 1 1)
      (bsd:fcntl a bsd:+f-setfl+ bsd:+o-nonblock+)
      (bsd:fcntl b bsd:+f-setfl+ bsd:+o-nonblock+)
      (is (eq :eagain (local-errno (lambda () (bsd:read b 1)))))
      (let ((data (make-array (+ bsd::+pipe-size+ 7) :element-type '(unsigned-byte 8)
                                                  :initial-element 11)))
        (is (= bsd::+pipe-size+ (bsd:write a data)) "partial nonblocking write")
        (is (eq :eagain (local-errno (lambda () (bsd:write a #(12))))))
        (is (equalp #(11 11 11) (bsd:read b 3)))
        (is (= 3 (bsd:write a #(12 13 14 15))))
        (let ((rest (bsd:read b bsd::+pipe-size+)))
          (is (= bsd::+pipe-size+ (length rest)))
          (is (equalp #(12 13 14) (subseq rest (- (length rest) 3))))))
      (bsd:shutdown b 0)
      (is (equalp #() (bsd:read b 1)))
      (is (eq :epipe (local-errno (lambda () (bsd:write a #(1)))))))))

(defun wait-local-syscall (proc)
  (loop :repeat 200
        :when (bsd::with-bsd (plusp (bsd::in-syscall proc))) :do (return t)
        :do (sleep 0.005)
        :finally (error "socket worker did not enter a blocking syscall")))

(defun local-worker (function)
  (let ((proc bsd:*proc*))
    (sb-thread:make-thread
     (lambda ()
       (let ((bsd:*proc* proc) (bsd:*proc0* proc))
         (handler-case (sb-ext:with-timeout 3 (funcall function))
           (error (e) e)))))))

(test local-stream-waiters-wake
  (with-local-process
    (multiple-value-bind (a b) (bsd:socketpair 1 1)
      (let ((reader (local-worker (lambda () (bsd:read b 3)))))
        (wait-local-syscall bsd:*proc*)
        (bsd:write a #(1 2 3))
        (is (equalp #(1 2 3) (sb-thread:join-thread reader))))
      (let ((reader (local-worker (lambda () (bsd:read b 1)))))
        (wait-local-syscall bsd:*proc*)
        (bsd:shutdown b 0)
        (is (equalp #() (sb-thread:join-thread reader)) "local read shutdown wakes read"))
      (let ((reader (local-worker (lambda () (bsd:read a 1)))))
        (wait-local-syscall bsd:*proc*)
        (bsd:close b)
        (is (equalp #() (sb-thread:join-thread reader)) "peer close wakes read")))))

(test local-stream-blocked-writers-wake
  (dolist (action '(:drain :close :shutdown))
    (with-local-process
      (multiple-value-bind (a b) (bsd:socketpair 1 1)
        (bsd:write a (make-array bsd::+pipe-size+ :element-type '(unsigned-byte 8)))
        (let ((writer (local-worker (lambda () (bsd:write a #(77))))))
          (wait-local-syscall bsd:*proc*)
          (ecase action
            (:drain (bsd:read b 1))
            (:close (bsd:close b))
            (:shutdown (bsd:shutdown a 1)))
          (let ((result (sb-thread:join-thread writer)))
            (if (eq action :drain)
                (is (eql 1 result))
                (is (and (typep result 'bsd:errno) (eq :epipe (bsd:errno-name result)))))))))))

(test local-stream-interrupted-write-keeps-progress
  (with-local-process
    (multiple-value-bind (a b) (bsd:socketpair 1 1)
      (let* ((size bsd::+pipe-size+)
             (writer (local-worker (lambda ()
                                     (bsd:write a (make-array (1+ size)
                                                             :element-type '(unsigned-byte 8)
                                                             :initial-element 33))))))
        (wait-local-syscall bsd:*proc*)
        (sb-thread:interrupt-thread writer (lambda () (bsd::fail :eintr)))
        (is (eql size (sb-thread:join-thread writer)))
        (is (= size (length (bsd:read b size))))))))

(test local-stream-errors-are-explicit
  (with-local-process
    (is (eq :eopnotsupp (local-errno (lambda () (bsd:socketpair 2 1)))))
    (is (eq :eafnosupport (local-errno (lambda () (bsd:socketpair 9999 1)))))
    (is (eq :eprotonosupport (local-errno (lambda () (bsd:socketpair 1 2)))))
    (is (eq :eprotonosupport (local-errno (lambda () (bsd:socketpair 1 1 6)))))
    (is (zerop (length (bsd::proc-fds bsd:*proc*))) "errors allocate no descriptors")
    (multiple-value-bind (a b) (bsd:socketpair 1 1)
      (declare (ignore b))
      (is (eq :einval (local-errno (lambda () (bsd:shutdown a 3)))))
      (is (eq :einval (local-errno (lambda () (bsd:read a -1)))))
      (is (eq :einval (local-errno (lambda () (bsd:bind a "localhost" 1)))))
      (is (eq :einval (local-errno (lambda () (bsd:listen a)))))
      (is (eq :einval (local-errno (lambda () (bsd:accept a)))))
      (is (eq :eisconn (local-errno (lambda () (bsd:connect a "localhost" 1))))))))

(test local-stream-foreign-abi
  (with-local-process
    (sb-alien:with-alien ((fds (array sb-alien:int 2)))
      (let* ((pointer (sb-sys:sap-int (sb-alien:alien-sap (sb-alien:addr fds))))
             (flags (logior 1 #o4000 #o2000000)))
        (setf (sb-alien:deref fds 0) -1 (sb-alien:deref fds 1) -1)
        (is (= 0 (bsd::libsa-entry 49 1 flags 0 pointer bsd:*proc*)))
        (let ((a (sb-alien:deref fds 0)) (b (sb-alien:deref fds 1)))
          (is (and (>= a 3) (>= b 3) (/= a b)) "never alias console descriptors")
          (is (= 1 (bsd::libsa-entry 29 a 1 0 0 bsd:*proc*)))
          (is (= #o4002 (bsd::libsa-entry 29 a 3 0 0 bsd:*proc*)))
          (is (eq :eagain (local-errno (lambda () (bsd:read b 1)))))
          (is (= 0 (bsd::libsa-entry 29 a 2 0 0 bsd:*proc*)))
          (is (= 0 (bsd::libsa-entry 29 a 1 0 0 bsd:*proc*)))
          (bsd:write a #(42))
          (is (equalp #(42) (bsd:read b 1)))
          (is (= 0 (bsd::libsa-entry 45 a 1 0 0 bsd:*proc*)))
          (is (equalp #() (bsd:read b 1))))
        (is (= -14 (bsd::libsa-entry 49 1 1 0 0 bsd:*proc*)))
        (is (= -22 (bsd::libsa-entry 49 1 #x1001 0 pointer bsd:*proc*)))))))

(test local-stream-world-service-reply
  (with-local-process
    ;; Exercise the same byte request and output relocation as port-vfs.
    ;; This operation does not invoke bulk-copy, so no live kernel token is needed.
    (let ((request (make-array 72 :element-type '(unsigned-byte 8) :initial-element 0)))
      (flet ((u64 (at value)
               (dotimes (i 8) (setf (aref request (+ at i)) (ldb (byte 8 (* 8 i)) value)))))
        (u64 0 1) (u64 8 49) (u64 16 1) (u64 24 1))
      (setf (aref request 60) 8 (aref request 67) 3)
      (let* ((reply (bsd:serve-request bsd:*proc* request 0))
             (a (bsd::request-u32 reply 24)) (b (bsd::request-u32 reply 28)))
        (is (= 32 (length reply)))
        (is (= 0 (bsd::request-u64 reply 0)))
        (is (= 8 (bsd::request-u32 reply 20)))
        (bsd:write a #(6 2 6))
        (is (equalp #(6 2 6) (bsd:read b 3)))))))

(defmacro with-local-filesystem (&body body)
  `(let ((darterfly/vfs:*root* nil) (darterfly/vfs::*cwd* nil) (darterfly/vfs:*mounts* nil)
         (darterfly/vfs::*files* (make-hash-table))
         (bsd::*local-names* (make-hash-table :test 'eq)))
     (darterfly/vfs:vfs-mount (darterfly/vfs:make-ram-node :vdir #o755) "/")
     (with-local-process ,@body)))

(test named-stream-lifetimes
  (with-local-filesystem
    (let ((server (bsd:socket 1 1)) (client (bsd:socket 1 1))
          (replacement (bsd:socket 1 1)))
      (is (= 0 (bsd:bind server "/nyxt")))
      (is (= #o140000 (logand #o170000 (getf (bsd:stat "/nyxt") :mode))))
      (is (eq :eaddrinuse (local-errno (lambda () (bsd:bind replacement "/nyxt")))))
      (is (eq :econnrefused (local-errno (lambda () (bsd:connect client "/nyxt")))))
      (bsd:listen server 1)
      (is (equal '(0) (bsd::poll-fds (list (list server 1)) 0)))
      (bsd:connect client "/nyxt")
      (is (equal '(1) (bsd::poll-fds (list (list server 1)) 0)))
      (let ((accepted (bsd:accept server)))
        (bsd:unlink "/nyxt")
        (is (eq :enoent (local-errno (lambda () (bsd:connect replacement "/nyxt")))))
        (bsd:bind replacement "/nyxt")
        (bsd:listen replacement)
        (bsd:close server)
        (is (= 1 (bsd:write client #(42))))
        (is (equalp #(42) (bsd:read accepted 1)))
        (let ((next (bsd:socket 1 1)))
          (bsd:connect next "/nyxt")
          (is (integerp (bsd:accept replacement))))))))

(test named-backlog-and-stale-names
  (with-local-filesystem
    (let ((server (bsd:socket 1 1)) (a (bsd:socket 1 1)) (b (bsd:socket 1 1)))
      (bsd:bind server "/nyxt")
      (bsd:listen server 1)
      (bsd:fcntl server bsd:+f-setfl+ bsd:+o-nonblock+)
      (is (eq :eagain (local-errno (lambda () (bsd:accept server)))))
      (bsd:connect a "/nyxt")
      (bsd:fcntl b bsd:+f-setfl+ bsd:+o-nonblock+)
      (is (eq :eagain (local-errno (lambda () (bsd:connect b "/nyxt")))))
      (bsd:accept server)
      (is (= 0 (bsd:connect b "/nyxt")))
      (bsd:close server)
      (is (equalp #() (bsd:read b 1)) "closing listener closes unaccepted peers")
      (let ((c (bsd:socket 1 1)))
        (is (eq :econnrefused (local-errno (lambda () (bsd:connect c "/nyxt")))))
        (is (eq :eaddrinuse (local-errno (lambda () (bsd:bind c "/nyxt")))))
        (bsd:unlink "/nyxt")
        (is (= 0 (bsd:bind c "/nyxt")))))))

(test poll-readiness-timeout-and-close
  (with-local-process
    (multiple-value-bind (a b) (bsd:socketpair 1 1)
      (is (equal '(0 4 0 32) (bsd::poll-fds (list (list a 1) (list a 4)
                                                               '(-1 5) '(99999 0)) 0)))
      (let ((start (get-internal-real-time)))
        (is (equal '(0) (bsd::poll-fds (list (list a 1)) 30)))
        (is (>= (/ (- (get-internal-real-time) start) internal-time-units-per-second) 0.025)))
      (let ((worker (local-worker (lambda () (bsd::poll-fds (list (list a 1)) -1)))))
        (wait-local-syscall bsd:*proc*)
        (bsd:write b #(7))
        (is (equal '(1) (sb-thread:join-thread worker))))
      (bsd:read a 1)
      (bsd:write a (make-array bsd::+pipe-size+ :element-type '(unsigned-byte 8)))
      (is (equal '(0) (bsd::poll-fds (list (list a 4)) 0)))
      (bsd:read b 1)
      (is (equal '(4) (bsd::poll-fds (list (list a 4)) 0)))
      (bsd:close b)
      (let ((events (first (bsd::poll-fds (list (list a 0)) 0))))
        (is (logtest events #x10) "hangup reported even without requested events")
        (is (logtest events #x8))))))

(test poll-pipes-and-regular-files
  (with-local-filesystem
    (multiple-value-bind (a b) (bsd:pipe)
      (is (equal '(0 4) (bsd::poll-fds (list (list a 1) (list b 4)) 0)))
      (bsd:write b #(1))
      (bsd:close b)
      (is (equal '(17) (bsd::poll-fds (list (list a 1)) 0)))
      (is (equalp #(1) (bsd:read a 1)))
      (is (equal '(16) (bsd::poll-fds (list (list a 1)) 0))))
    (let ((fd (bsd:open "/file" (logior bsd:+o-creat+ bsd:+o-rdwr+))))
      (is (equal '(5) (bsd::poll-fds (list (list fd 5)) 0))))))

(test named-accept-and-backlog-wake
  (with-local-filesystem
    (let ((server (bsd:socket 1 1)) (a (bsd:socket 1 1))
          (b (bsd:socket 1 1)))
      (bsd:bind server "/nyxt")
      (bsd:listen server 1)
      (let ((worker (local-worker (lambda () (bsd:accept server)))))
        (wait-local-syscall bsd:*proc*)
        (bsd:connect a "/nyxt")
        (is (integerp (sb-thread:join-thread worker))))
      ;; Worker threads don't inherit dynamic VFS bindings; capture them.
      (bsd:connect b "/nyxt")
      (let* ((c (bsd:socket 1 1))
             (root darterfly/vfs:*root*)
             (cwd darterfly/vfs::*cwd*)
             (names bsd::*local-names*)
             (worker
               (local-worker
                (lambda ()
                  (let ((darterfly/vfs:*root* root)
                        (darterfly/vfs::*cwd* cwd)
                        (darterfly/vfs:*mounts* nil)
                        (bsd::*local-names* names))
                    (bsd:connect c "/nyxt"))))))
        (wait-local-syscall bsd:*proc*)
        (bsd:accept server)
        (is (eql 0 (sb-thread:join-thread worker)))))))

(test poll-interruption-and-world-teardown
  (with-local-process
    (let ((worker (local-worker (lambda () (bsd::poll-fds nil -1)))))
      (wait-local-syscall bsd:*proc*)
      (sb-thread:interrupt-thread worker (lambda () (bsd::fail :eintr)))
      (let ((result (sb-thread:join-thread worker)))
        (is (and (typep result 'bsd:errno) (eq :eintr (bsd:errno-name result)))))))
  (let* ((bsd:*proc* (bsd:make-world-proc "/"))
         (worker (local-worker (lambda () (bsd::poll-fds nil -1)))))
    (unwind-protect
         (progn
           (wait-local-syscall bsd:*proc*)
           (bsd:end-world-proc bsd:*proc*)
           (let ((result (sb-thread:join-thread worker)))
             (is (and (typep result 'bsd:errno)
                      (eq :eintr (bsd:errno-name result))))))
      (bsd:end-world-proc bsd:*proc*))))

(test poll-network-queue-state
  (with-local-process
    (let* ((fd (bsd:socket 2 1))
           (s (bsd::fd-socket fd))
           (pcb (darterfly/net::make-connection :state :established)))
      (setf (bsd::socket-pcb s) pcb)
      (unwind-protect
           (progn
             (is (equal '(4) (bsd::poll-fds (list (list fd 5)) 0)))
             (vector-push-extend 42 (darterfly/net::tcp-received pcb))
             (is (equal '(5) (bsd::poll-fds (list (list fd 5)) 0)))
             (setf (darterfly/net::tcp-reset pcb) t)
             (is (logtest #x18 (first (bsd::poll-fds (list (list fd 0)) 0)))))
        ;; A synthetic PCB has no live TCP peer to complete a close handshake.
        (setf (bsd::socket-pcb s) nil)))))

(test poll-world-request-bounds
  (with-local-process
    (let ((request (make-array 80 :element-type '(unsigned-byte 8)
                                  :initial-element 0)))
      (setf (aref request 0) 1 (aref request 8) 50
            (aref request 16) 1 (aref request 24) 1
            (aref request 48) 8 (aref request 64) 6)
      ;; A negative pollfd is ignored, and revents is overwritten on return.
      (fill request 255 :start 72 :end 76)
      (setf (aref request 78) 99)
      (let ((reply (bsd:serve-request bsd:*proc* request 0)))
        (is (= 0 (bsd::request-u64 reply 0)))
        (is (= 8 (bsd::request-u32 reply 8)))
        (is (= 0 (aref reply 30))))
      (setf (aref request 24) 2)
      (is (= -22 (bsd::signed (bsd::request-u64
                              (bsd:serve-request bsd:*proc* request 0) 0))))
      (setf (aref request 24) 1)
      (is (= -22 (bsd::signed (bsd::request-u64
                              (bsd:serve-request bsd:*proc* (subseq request 0 72) 0) 0)))))))

(in-suite guest)

(test socketpair-c-abi-on-darterfly
  (let* ((disk (merge-pathnames "socketpair.img" (scratch)))
         (entries (append (image::root-entries)
                          (list (list :file "Users/darterfly/socketpair-probe.c"
                                      (image::octets (darterfly-file "tests/socketpair-probe.c")))))))
    (image::root-disk disk (* 512 1048576) entries)
    (let ((c (image:bare-console :root disk)))
      (flet ((ask (form)
               (image:send c form)
               (image:expect c (format nil "~%* ") :timeout 180)))
        (unwind-protect
             (progn
               (image:expect c "* " :timeout 90)
               (is (search "[SOCKETPAIR 0]"
                           (ask "(format nil \"[SOCKETPAIR ~a]\" (darterfly/cc:run-c \"/Users/darterfly/socketpair-probe.c\"))"))
                   "the C probe compiles and runs in the system world")
               (ask "(darterfly/install::esp)")
               (let ((code "(let ((status (darterfly/cc:run-c \"/Users/darterfly/socketpair-probe.c\"))) (with-open-file (s \"/tmp/socketpair-result\" :direction :output :if-exists :supersede) (prin1 status s)) (sb-ext:exit :code (if (eql status 0) 0 1)))"))
                 (is (search "(:EXIT 0 :FILES 0)"
                             (ask (format nil "(darterfly/run:run-world \"/Volumes/EFI/EFI/darterfly/gen-1/darterfly.core\" (darterfly/run::world-argv ~s) :cwd \"/\" :disk t :timeout 120)" code)))
                     "an isolated world uses the actual port-vfs socketpair bridge"))
               (is (search "[RESULT 0]"
                           (ask "(format nil \"[RESULT ~a]\" (uiop:read-file-string \"/tmp/socketpair-result\"))")))
               (ask "(defparameter *nyxt-server* (darterfly/bsd:socket 1 1))")
               (ask "(darterfly/bsd:bind *nyxt-server* \"/tmp/nyxt-world.sock\")")
               (ask "(darterfly/bsd:listen *nyxt-server*)")
               (ask "(defparameter *nyxt-worker* (sb-thread:make-thread (lambda () (let ((fd (darterfly/bsd:accept *nyxt-server*))) (unwind-protect (progn (unless (equalp #(110) (darterfly/bsd:read fd 1)) (error \"bad request\")) (sleep 0.1) (darterfly/bsd:write fd #(121))) (darterfly/bsd:close fd))))))")
               (let ((code "(let ((status (darterfly/cc:run-c \"/Users/darterfly/socketpair-probe.c\" :args '(\"client\")))) (with-open-file (s \"/tmp/cross-world-result\" :direction :output :if-exists :supersede) (prin1 status s)) (sb-ext:exit :code (if (eql status 0) 0 1)))"))
                 (is (search "(:EXIT 0 :FILES 0)"
                             (ask (format nil "(darterfly/run:run-world \"/Volumes/EFI/EFI/darterfly/gen-1/darterfly.core\" (darterfly/run::world-argv ~s) :cwd \"/\" :disk t :timeout 120)" code)))
                     "isolated C client talks to a system-world Lisp listener"))
               (is (search "[CROSS 0]"
                           (ask "(format nil \"[CROSS ~a]\" (uiop:read-file-string \"/tmp/cross-world-result\"))")))
               (is (search "[SERVER 1]"
                           (ask "(format nil \"[SERVER ~a]\" (sb-thread:join-thread *nyxt-worker* :timeout 5 :default :timeout))")))
               (ask "(darterfly/bsd:close *nyxt-server*)")
               (ask "(darterfly/bsd:unlink \"/tmp/nyxt-world.sock\")")
               (is (search "[ALIVE 42]" (ask "(format nil \"[ALIVE ~a]\" (+ 40 2))"))))
          (image:finish c 5))))))

(in-suite local-socket)

(test ancillary-rights-survive-close-and-share-offset
  (with-local-process
    (multiple-value-bind (a b) (bsd:socketpair 1 1)
      (multiple-value-bind (r w) (bsd:pipe)
        (let ((file (bsd::fd-file w)))
          (is (= 1 (bsd:send-message a #(7) (list w))))
          (bsd:close w)
          (is (= 1 (bsd::file-refs file)))
          (multiple-value-bind (bytes rights flags) (bsd:receive-message b 10 1 #x40000000)
            (is (equalp #(7) bytes)) (is (zerop flags))
            (is (= 1 (length rights)))
            (is (cdr (aref (bsd::proc-fds bsd:*proc*) (first rights))))
            (is (= 2 (bsd:write (first rights) #(11 12))))
            (is (equalp #(11 12) (bsd:read r 2)))
            (bsd:close (first rights)))
          (is (zerop (bsd::file-refs file))))))))

(test ancillary-boundary-peek-and-truncation
  (with-local-process
    (multiple-value-bind (a b) (bsd:socketpair 1 1)
      (multiple-value-bind (r w) (bsd:pipe)
        (declare (ignore r))
        (bsd:write a #(1 2))
        (bsd:send-message a #(3 4) (list w))
        (bsd:write a #(5))
        (is (equalp #(1) (bsd:read b 1)))
        (multiple-value-bind (bytes rights flags) (bsd:receive-message b 10 1 2)
          (is (equalp #(2 3 4) bytes)) (is (zerop flags))
          (is (= 1 (length rights))) (bsd:close (first rights)))
        (multiple-value-bind (bytes rights flags) (bsd:receive-message b 10 0)
          (is (equalp #(2 3 4) bytes)) (is (null rights)) (is (= 8 flags)))
        (is (equalp #(5) (bsd:read b 1)))
        (is (= 1 (bsd::file-refs (bsd::fd-file w))))))))

(test ancillary-discard-and-invalid-send
  (with-local-process
    (multiple-value-bind (a b) (bsd:socketpair 1 1)
      (let ((f (bsd::fd-file a)))
        (is (eq :ebadf (local-errno (lambda () (bsd:send-message a #(1) (list a 999))))))
        (is (= 1 (bsd::file-refs f))))
      (bsd:send-message a #(1) (list a))
      (is (= 2 (bsd::file-refs (bsd::fd-file a))))
      (is (equalp #(1) (bsd:read b 1)))
      (is (= 1 (bsd::file-refs (bsd::fd-file a))))
      (bsd:shutdown b 0)
      (is (eq :epipe (local-errno (lambda () (bsd:send-message a #(1) nil #x4000))))))))

(test ancillary-socket-cycles-are-collected
  (with-local-process
    (let ((before (hash-table-count bsd::*control-buffers*)))
      (multiple-value-bind (a b) (bsd:socketpair 1 1)
        (let ((fa (bsd::fd-file a)) (fb (bsd::fd-file b)))
          (bsd:send-message a #(1) (list a))
          (bsd:send-message b #(2) (list b))
          (bsd:close a)
          (is (plusp (bsd::file-refs fa)))
          (bsd:close b)
          (is (zerop (bsd::file-refs fa)))
          (is (zerop (bsd::file-refs fb)))
          (is (= before (hash-table-count bsd::*control-buffers*))))))))

(test local-seqpacket-records-and-rights
  (with-local-process
    (multiple-value-bind (a b) (bsd:socketpair 1 5)
      (bsd:send-message a #(1 2 3) (list a))
      (bsd:send-message a #(4 5) nil)
      (is (equal '(1) (bsd::poll-fds (list (list b 1)) 0)))
      (multiple-value-bind (bytes rights flags size) (bsd:receive-message b 1 1 #x20)
        (is (equalp #(1) bytes)) (is (= 3 size)) (is (= #x20 flags))
        (is (= 1 (length rights))) (bsd:close (first rights)))
      (is (equalp #(4 5) (bsd:read b 10)))
      (bsd:send-message a #() nil)
      (is (equal '(1) (bsd::poll-fds (list (list b 1)) 0)))
      (is (equalp #() (bsd:read b 10)))
      (is (equal '(0) (bsd::poll-fds (list (list b 1)) 0))))))

(test ancillary-backpressure-and-shutdown-release-ownership
  (with-local-process
    (multiple-value-bind (a b) (bsd:socketpair 1 5)
      (let ((file (bsd::fd-file a)))
        (dotimes (i 256) (bsd:send-message a #() nil))
        (is (eq :eagain
                (local-errno (lambda () (bsd:send-message a #(1) (list a) #x40)))))
        (is (= 1 (bsd::file-refs file)))
        (bsd:read b 1)
        (is (= 1 (bsd:send-message a #(2) (list a) #x40)))
        (is (= 2 (bsd::file-refs file)))
        (bsd:shutdown b 0)
        (is (= 1 (bsd::file-refs file)))))))

(test named-seqpacket-preserves-records
  (with-local-filesystem
    (let ((server (bsd:socket 1 5)) (client (bsd:socket 1 5))
          (wrong (bsd:socket 1 1)))
      (bsd:bind server "/packet")
      (bsd:listen server)
      (is (eq :eprototype (local-errno (lambda () (bsd:connect wrong "/packet")))))
      (bsd:connect client "/packet")
      (let ((peer (bsd:accept server)))
        (bsd:write client #(1 2 3)) (bsd:write client #(4))
        (is (equalp #(1) (bsd:read peer 1)))
        (is (equalp #(4) (bsd:read peer 10)))))))

(test shared-ram-core-save-keeps-bytes-not-addresses
  (let* ((darterfly/vfs::*shared-ram-nodes* nil)
         (n (darterfly/vfs:make-ram-node :vreg #o600))
         (sap nil))
    (unwind-protect
         (progn
           (darterfly/vfs:vnop-write n 0 #(1 2 3))
           (setf sap (darterfly/vfs::promote-shared-data n))
           (setf (sb-sys:sap-ref-8 sap 1) 9)
           (is (equalp #(1 9 3) (darterfly/vfs:vnop-read n 0 3)))
           (darterfly/vfs:vnop-write n 3 #(4))
           (is (= 4 (sb-sys:sap-ref-8 sap 3)))
           (darterfly/vfs:vnop-truncate n 8)
           (is (equalp #(1 9 3 4 0 0 0 0) (darterfly/vfs:vnop-read n 0 8)))
           (signals darterfly/vfs:vfs-error (darterfly/vfs:vnop-truncate n 3))
           (darterfly/vfs::save-shared-ram-data)
           (is (null (darterfly/vfs::node-external n)))
           (is (zerop (darterfly/vfs::node-shared-capacity n)))
           (is (equalp #(1 9 3 4 0 0 0 0) (darterfly/vfs:vnop-read n 0 8))))
      (when sap
        (sb-ext:cancel-finalization n)
        (sb-posix:munmap sap darterfly/vfs::+shared-file-capacity+)))))
