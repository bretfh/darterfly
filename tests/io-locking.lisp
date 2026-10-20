(in-package #:darterfly/test)

(def-suite io-locking :in host)
(in-suite io-locking)

(defclass gated-io-node (darterfly/vfs:vnode)
  ((entered :initform (sb-thread:make-semaphore) :reader io-entered)
   (release :initform (sb-thread:make-semaphore) :reader io-release)
   (offsets :initform nil :accessor io-offsets)))

(defmethod darterfly/vfs:vnop-write ((node gated-io-node) offset octets)
  (push offset (io-offsets node))
  (sb-thread:signal-semaphore (io-entered node))
  (unless (sb-thread:wait-on-semaphore (io-release node) :timeout 5)
    (error "test storage gate timed out"))
  (length octets))

(defmacro with-io-process (&body body)
  `(let* ((bsd:*proc0* (make-instance 'bsd:proc :pid 0 :task mach:*task*))
          (bsd:*proc* bsd:*proc0*)
          (darterfly/vfs::*files* (make-hash-table)))
     ,@body))

(defun install-io-node (node)
  (bsd::with-bsd
    (bsd::fd-alloc
     (make-instance 'bsd::vnode :fd
       (darterfly/vfs::with-vfs
         (darterfly/vfs::install
          (darterfly/vfs::make-file :vnode node :flags '(:access :rdwr))))))))

(defun io-worker (fn)
  (let ((proc bsd:*proc*) (files darterfly/vfs::*files*))
    (sb-thread:make-thread
     (lambda ()
       (let ((bsd:*proc* proc) (bsd:*proc0* proc) (darterfly/vfs::*files* files))
         (funcall fn))) :name "test stalled I/O")))

(test stalled-file-write-does-not-block-process-inspection
  (with-io-process
    (let* ((node (make-instance 'gated-io-node :type :vreg))
           (fd (install-io-node node))
           (writer (io-worker (lambda () (bsd:write fd #(1 2 3)))))
           (inspector nil) (done (sb-thread:make-semaphore)))
      (unwind-protect
           (progn
             (is (sb-thread:wait-on-semaphore (io-entered node) :timeout 2))
             (setf inspector (io-worker (lambda () (bsd:procs) (sb-thread:signal-semaphore done))))
             (is (sb-thread:wait-on-semaphore done :timeout .3)
                 "storage must not hold the process inspection lock"))
        (sb-thread:signal-semaphore (io-release node))
        (is (= 3 (sb-thread:join-thread writer :timeout 6)))
        (when inspector (sb-thread:join-thread inspector :timeout 6))
        (bsd:close fd)))))

(test closing-and-reusing-a-descriptor-preserves-in-flight-io
  (with-io-process
    (let* ((node (make-instance 'gated-io-node :type :vreg))
           (fd (install-io-node node))
           (file (bsd::with-bsd (bsd::fd-file fd)))
           (writer (io-worker (lambda () (bsd:write fd #(1 2 3)))))
           (closer nil) (done (sb-thread:make-semaphore)) (replacement nil))
      (unwind-protect
           (progn
             (is (sb-thread:wait-on-semaphore (io-entered node) :timeout 2))
             (setf closer
                   (io-worker (lambda ()
                                (bsd:close fd)
                                (bsd::with-bsd
                                  (setf replacement (bsd::fd-alloc (make-instance 'bsd::file))))
                                (sb-thread:signal-semaphore done))))
             (is (sb-thread:wait-on-semaphore done :timeout .3))
             (is (eql replacement fd))
             (is (= 1 (bsd::file-refs file)) "in-flight reference survives close")
             (is (eq node (darterfly/vfs::file-vnode
                           (darterfly/vfs::fd-file (bsd::vfs-fd file))))))
        (sb-thread:signal-semaphore (io-release node))
        (is (= 3 (sb-thread:join-thread writer :timeout 6)))
        (when closer (sb-thread:join-thread closer :timeout 6))
        (when replacement (bsd:close replacement)))
      (is (zerop (bsd::file-refs file)))
      (is (zerop (hash-table-count darterfly/vfs::*files*))))))

(test duplicates-serialize-shared-offsets-without-blocking-bsd
  (with-io-process
    (let* ((node (make-instance 'gated-io-node :type :vreg))
           (fd (install-io-node node)) (copy (bsd:dup fd))
           (first (io-worker (lambda () (bsd:write fd #(1 2 3)))))
           (second nil))
      (unwind-protect
           (progn
             (is (sb-thread:wait-on-semaphore (io-entered node) :timeout 2))
             (setf second (io-worker (lambda () (bsd:write copy #(4 5)))))
             (sb-thread:signal-semaphore (io-release node))
             (is (= 3 (sb-thread:join-thread first :timeout 6)))
             (is (sb-thread:wait-on-semaphore (io-entered node) :timeout 2))
             (sb-thread:signal-semaphore (io-release node))
             (is (= 2 (sb-thread:join-thread second :timeout 6)))
             (is (equal '(0 3) (reverse (io-offsets node))))
             (is (= 5 (bsd:lseek fd 0 :cur))))
        (sb-thread:signal-semaphore (io-release node) 2)
        (sb-thread:join-thread first :timeout 6 :default nil)
        (when second (sb-thread:join-thread second :timeout 6 :default nil))
        (bsd:close fd) (bsd:close copy)))))

(test file-errors-and-interrupts-release-references-and-bsd
  (with-io-process
    (let* ((node (make-instance 'gated-io-node :type :vreg))
           (fd (install-io-node node))
           (file (bsd::with-bsd (bsd::fd-file fd)))
           (worker (io-worker (lambda () (handler-case (bsd:write fd #(1))
                                          (error () :interrupted))))))
      (unwind-protect
           (progn
             (is (sb-thread:wait-on-semaphore (io-entered node) :timeout 2))
             (sb-thread:interrupt-thread worker (lambda () (error "cancel test I/O")))
             (is (eq :interrupted (sb-thread:join-thread worker :timeout 2)))
             (is (= 1 (bsd::file-refs file)))
             (is (zerop (bsd::in-syscall bsd:*proc*)))
             (is (not (null (bsd:procs)))))
        (sb-thread:signal-semaphore (io-release node))
        (sb-thread:join-thread worker :timeout 6 :default nil)
        (bsd:close fd)))))

(test service-output-is-bounded-and-survives-descriptor-close
  (with-io-process
    (let* ((job (init::load-job '(:label "capture-test" :world t)))
           (file (init::job-errors job)))
      (bsd::with-bsd
        (bsd::spawn-file-actions (list (list :capture 2 file))))
      (bsd:write 2 (make-array 40000 :element-type '(unsigned-byte 8) :initial-element 65))
      (bsd:write 2 #(66 67))
      (bsd:close 2)
      (let ((record (bsd::captured-output file 3)))
        (is (= 40002 (getf record :bytes)))
        (is (= 39999 (getf record :omitted)))
        (is (equal "ABC" (getf record :text)))))))

(test recovery-eval-does-not-wait-for-the-journal
  (let ((gate (sb-thread:make-semaphore)) (release (sb-thread:make-semaphore))
        (output nil) (worker nil))
    (unwind-protect
         (progn
           (setf worker (sb-thread:make-thread
                         (lambda ()
                           (sb-thread:with-mutex (darterfly/journal::*journal-lock*)
                             (sb-thread:signal-semaphore gate)
                             (sb-thread:wait-on-semaphore release :timeout 5)))))
           (is (sb-thread:wait-on-semaphore gate :timeout 2))
           (is (equal '("done")
                 (sb-ext:with-timeout 1
                   (darterfly/nrepl::%eval-code (darterfly/nrepl::make-session) "(+ 20 22)"
                     (lambda (&rest kvs) (push kvs output)) nil))))
           (is (member '("journal" "skipped") output :test #'equal))
           (is (find "42" output :test #'equal :key #'second)))
      (sb-thread:signal-semaphore release)
      (when worker (sb-thread:join-thread worker :timeout 6)))))

(test diagnostics-do-not-wait-for-bsd-or-vfs
  (let ((gate (sb-thread:make-semaphore)) (release (sb-thread:make-semaphore))
        (worker nil) (darterfly/devices:*registry-root* nil))
    (unwind-protect
         (progn
           (setf worker (sb-thread:make-thread
                         (lambda ()
                           (bsd::with-bsd
                             (darterfly/vfs::with-vfs
                               (sb-thread:signal-semaphore gate)
                               (sb-thread:wait-on-semaphore release :timeout 5))))
                         :name "test locked system"))
           (is (sb-thread:wait-on-semaphore gate :timeout 2))
           (let ((snapshot (sb-ext:with-timeout 1 (darterfly/nrepl::diagnostic-snapshot))))
             (is (find "test locked system" (getf snapshot :locks)
                       :key (lambda (lock) (getf lock :owner)) :test #'equal))))
      (sb-thread:signal-semaphore release)
      (when worker (sb-thread:join-thread worker :timeout 6)))))

(test waiting-metadata-and-close-do-not-reacquire-bsd-around-vfs
  (with-io-process
    (let* ((root (darterfly/vfs:make-ram-node :vdir #o755))
           (darterfly/vfs:*root* root)
           (darterfly/vfs::*cwd* (list (cons "" root)))
           (gate (sb-thread:make-semaphore)) (release (sb-thread:make-semaphore))
           (done (sb-thread:make-semaphore)) (locker nil) (opener nil) (probe nil)
           (fd (bsd:open "/pending" (logior bsd:+o-creat+ bsd:+o-rdwr+))))
      (unwind-protect
           (progn
             (setf locker (io-worker (lambda ()
                                      (darterfly/vfs::with-vfs
                                        (sb-thread:signal-semaphore gate)
                                        (sb-thread:wait-on-semaphore release :timeout 5)))))
             (is (sb-thread:wait-on-semaphore gate :timeout 2))
             (let ((cwd darterfly/vfs::*cwd*))
               (setf opener (io-worker (lambda ()
                                        (let ((darterfly/vfs:*root* root) (darterfly/vfs::*cwd* cwd))
                                          (bsd:close (bsd:open "/pending" bsd:+o-rdonly+)))))))
             ;; Synchronize on the actual VFS waiter, not a guessed delay.
             (is (loop repeat 200
                       thereis (eq (sb-thread::thread-waiting-for opener) darterfly/vfs::*lock*)
                       do (sleep .005)))
             (setf probe (io-worker (lambda () (bsd:close fd) (bsd:procs)
                                     (sb-thread:signal-semaphore done))))
             (is (sb-thread:wait-on-semaphore done :timeout .3)))
        (sb-thread:signal-semaphore release)
        (dolist (thread (list locker opener probe))
          (when thread (sb-thread:join-thread thread :timeout 6 :default nil)))))))

(defclass gated-lock-node (gated-io-node) ())

(defmethod darterfly/vfs:vnop-getattr ((node gated-lock-node))
  (sb-thread:signal-semaphore (io-entered node))
  (unless (sb-thread:wait-on-semaphore (io-release node) :timeout 5)
    (error "test lock metadata gate timed out"))
  (darterfly/vfs:make-vattr :mode #o100644 :size 64))

(test stalled-record-lock-metadata-allows-inspection-and-close
  (with-io-process
    (let* ((node (make-instance 'gated-lock-node :type :vreg))
           (fd (install-io-node node))
           (worker (io-worker
                    (lambda () (local-errno
                                (lambda () (bsd::record-lock fd 6 1 2 0 1))))))
           (probe nil) (replacement nil) (done (sb-thread:make-semaphore)))
      (unwind-protect
           (progn
             (is (sb-thread:wait-on-semaphore (io-entered node) :timeout 2))
             (setf probe
                   (io-worker
                    (lambda ()
                      (bsd:procs)
                      (bsd:close fd)
                      (bsd::with-bsd
                        (setf replacement
                              (bsd::fd-alloc (make-instance 'bsd::file))))
                      (sb-thread:signal-semaphore done))))
             (is (sb-thread:wait-on-semaphore done :timeout .3))
             (is (eql fd replacement)))
        (sb-thread:signal-semaphore (io-release node))
        (is (eq :ebadf (sb-thread:join-thread worker :timeout 6)))
        (when probe (sb-thread:join-thread probe :timeout 6))
        (when replacement (bsd:close replacement)))
      (is (null (gethash node bsd::*record-locks*)))
      (is (zerop (hash-table-count darterfly/vfs::*files*))))))

(in-suite guest)

(defun inspection-rpc (port code &key (op "eval") (journal "skip"))
  (sb-ext:with-timeout 5
    (let ((socket (make-instance 'sb-bsd-sockets:inet-socket :type :stream :protocol :tcp))
          (stream nil))
      (unwind-protect
           (progn
             (sb-bsd-sockets:socket-connect socket #(127 0 0 1) port)
             (setf stream (sb-bsd-sockets:socket-make-stream socket :input t :output t
                                                          :element-type '(unsigned-byte 8)))
             (darterfly/nrepl::send stream
               (darterfly/nrepl::%msg "op" op "key" "inspection-test" "id" "inspect"
                                      "journal" journal "code" (or code "")))
             (loop for message = (darterfly/nrepl::read-message stream)
                   collect message
                   until (assoc "status" message :test #'equal)))
        (if stream (close stream) (sb-bsd-sockets:socket-close socket))))))

(test inspection-and-recovery-work-while-storage-is-stalled
  (let* ((port (free-udp-port))
         (c (image:bare-console :boot-args "init nrepl-key=inspection-test"
                                :forwards (list (list :tcp port 4011))))
         (normal nil) (answer nil))
    (unwind-protect
         (progn
           (image:expect c "init: pid 1" :timeout 120)
           ;; Prime ARP before applying an interactive latency bound.
           (inspection-rpc port nil :op "diagnostics")
           (inspection-rpc port
             "(progn (defvar *inspection-gate* (sb-thread:make-semaphore))
                     (defvar *inspection-entered* (sb-thread:make-semaphore))
                     (sb-thread:make-thread
                       (lambda () (darterfly/vfs::with-vfs
                         (sb-thread:signal-semaphore *inspection-entered*)
                         (sb-thread:wait-on-semaphore *inspection-gate* :timeout 20)))
                       :name \"stalled storage regression\")
                     (sb-thread:wait-on-semaphore *inspection-entered* :timeout 5))")
           (setf normal (sb-thread:make-thread
                         (lambda () (setf answer (inspection-rpc port "42" :journal "record")))))
           (let ((text (loop repeat 30
                             for snapshot = (prin1-to-string (inspection-rpc port nil :op "diagnostics"))
                             when (and (search "journal" snapshot) (search "nrepl eval" snapshot)) return snapshot
                             do (sleep .01))))
             (is (search "stalled storage regression" text))
             (is (not (search "inspection-test" text)) "credential is redacted from kernel output"))
           (let* ((start (get-internal-real-time))
                  (result (inspection-rpc port "(list :answer 42 :processes (length (darterfly/bsd:procs)))")))
             (is (< (- (get-internal-real-time) start) internal-time-units-per-second))
             (is (search ":ANSWER 42" (prin1-to-string result)))
             (is (search "skipped" (prin1-to-string result))))
           (is (null answer) "ordinary journaling is still waiting, not silently disabled")
           (inspection-rpc port "(sb-thread:signal-semaphore *inspection-gate*)")
           (sb-thread:join-thread normal :timeout 5)
           (is (search "42" (prin1-to-string answer))))
      (ignore-errors (inspection-rpc port "(when (boundp '*inspection-gate*) (sb-thread:signal-semaphore *inspection-gate*))"))
      (when (and normal (sb-thread:thread-alive-p normal))
        (sb-thread:join-thread normal :timeout 6 :default nil))
      (image:finish c 2))))

(in-suite io-locking)
(test service-stream-flushes-long-lines-in-bounded-chunks
  (with-io-process
    (let ((file (make-instance 'bsd::capture-file)))
      (bsd::with-bsd (bsd::spawn-file-actions (list (list :capture 2 file))))
      (let ((stream (make-instance 'bsd::fd-stream :fd 2)))
        (write-string (make-string 5000 :initial-element #\a) stream)
        (is (= 4096 (getf (bsd::captured-output file) :bytes)))
        (is (< (length (bsd::out stream)) 4096))
        (finish-output stream)
        (is (= 5000 (getf (bsd::captured-output file) :bytes))))
      (bsd:close 2))))

(test an-open-finishing-after-process-exit-does-not-publish-a-descriptor
  (with-io-process
    (let* ((root (darterfly/vfs:make-ram-node :vdir #o755))
           (darterfly/vfs:*root* root) (darterfly/vfs::*cwd* (list (cons "" root)))
           (entered (sb-thread:make-semaphore)) (release (sb-thread:make-semaphore))
           (locker nil) (opener nil))
      (unwind-protect
           (progn
             (setf locker (io-worker (lambda ()
                                      (darterfly/vfs::with-vfs
                                        (sb-thread:signal-semaphore entered)
                                        (sb-thread:wait-on-semaphore release :timeout 5)))))
             (is (sb-thread:wait-on-semaphore entered :timeout 2))
             (let ((cwd darterfly/vfs::*cwd*))
               (setf opener
                     (io-worker (lambda ()
                                  (let ((darterfly/vfs:*root* root) (darterfly/vfs::*cwd* cwd))
                                    (local-errno (lambda ()
                                                   (bsd:open "/late" (logior bsd:+o-creat+ bsd:+o-rdwr+)))))))))
             (is (loop repeat 200
                       thereis (eq (sb-thread::thread-waiting-for opener) darterfly/vfs::*lock*)
                       do (sleep .005)))
             (bsd::with-bsd (setf (bsd::proc-closing bsd:*proc*) t))
             (sb-thread:signal-semaphore release)
             (is (eq :eintr (sb-thread:join-thread opener :timeout 6)))
             (is (zerop (hash-table-count darterfly/vfs::*files*))))
        (sb-thread:signal-semaphore release)
        (dolist (thread (list locker opener))
          (when thread (sb-thread:join-thread thread :timeout 6 :default nil)))))))

(test descriptor-table-errors-do-not-stop-with-a-system-lock-held
  (sb-thread:with-mutex (darterfly/vfs::*files-lock*)
    (is (member "vfs descriptors" (bsd::system-locks-held) :test #'equal))))

(test spawn-preparation-reserves-its-pid-and-rechecks-parent-exit
  (with-io-process
    (let ((entered (sb-thread:make-semaphore)) (release (sb-thread:make-semaphore))
          (pid nil) (ran nil) (worker nil))
      (unwind-protect
           (progn
             (setf worker
                   (io-worker (lambda ()
                                (local-errno
                                 (lambda ()
                                   (bsd:fork (lambda () (setf ran t) 0)
                                     :prepare
                                     (lambda ()
                                       (setf pid (bsd:proc-pid bsd:*proc*))
                                       (bsd::without-bsd
                                         (sb-thread:signal-semaphore entered)
                                         (sb-thread:wait-on-semaphore release :timeout 5)))))))))
             (is (sb-thread:wait-on-semaphore entered :timeout 2))
             (bsd::with-bsd
               (is (gethash pid bsd::*preparing-pids*))
               (let ((bsd::*next-pid* (1- pid)))
                 (is (/= pid (bsd::next-pid))))
               (setf (bsd::proc-closing bsd:*proc*) t))
             (sb-thread:signal-semaphore release)
             (is (eq :eintr (sb-thread:join-thread worker :timeout 6)))
             (is (null ran))
             (is (null (gethash pid bsd::*preparing-pids*)))
             (is (null (gethash pid bsd::*procs*))))
        (sb-thread:signal-semaphore release)
        (when worker (sb-thread:join-thread worker :timeout 6 :default nil))))))
