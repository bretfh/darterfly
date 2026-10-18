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
      (is (eq :eopnotsupp (local-errno (lambda () (bsd:bind a "localhost" 1)))))
      (is (eq :eopnotsupp (local-errno (lambda () (bsd:listen a)))))
      (is (eq :eopnotsupp (local-errno (lambda () (bsd:accept a)))))
      (is (eq :eopnotsupp (local-errno (lambda () (bsd:connect a "localhost" 1))))))))

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
               (is (search "[ALIVE 42]" (ask "(format nil \"[ALIVE ~a]\" (+ 40 2))"))))
          (image:finish c 5))))))
