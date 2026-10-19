(in-package #:darterfly/bsd)

;; One receive right for all BSD native children. Kernel-supplied sender IDs,
;; never a PID in the request, select the owning BSD descriptor table.
(defconstant +native-io-limit+ 4096)
(defvar *native-port* nil)
(defvar *native-dispatcher* nil)
(defvar *native-processes* (make-hash-table))

(defun native-put (bytes at value &optional (size 8))
  (dotimes (i size)
    (setf (aref bytes (+ at i)) (ldb (byte 8 (* 8 i)) value)))
  bytes)

(defun native-reply-token (token reply)
  ;; A caller killed after delivery can abandon its token before we reply.
  (handler-case (darterfly/worlds:reply token reply)
    (darterfly/worlds:world-error () nil)))

(defun native-dispatch ()
  (let ((*proc* *proc0*))
    (loop
      (handler-case
          (multiple-value-bind (message token world)
              (darterfly/worlds:receive *native-port* :timeout 0.01)
            (let ((queued
                    (with-bsd
                      (let ((proc (gethash world *native-processes*)))
                        (when (and proc (not (proc-native-result proc))
                                   (< (length (proc-native-requests proc)) 16))
                          (setf (proc-native-requests proc)
                                (nconc (proc-native-requests proc)
                                       (list (cons token message))))
                          (changed)
                          t)))))
              (unless queued (native-reply-token token (reply-octets -4 '(0 0 0 0) #() '(0 0 0 0))))))
        (darterfly/worlds:world-error (e)
          (unless (member (darterfly/worlds::world-error-code e) '(4 110))
            (error e))))
      ;; A native world may die while its process thread services a blocking
      ;; read/poll. Wake that operation before waiting for the Lisp thread.
      (with-bsd
        (maphash
         (lambda (world proc)
           (unless (proc-native-result proc)
             (let ((status (darterfly/worlds:wait-native world :nohang t)))
               (when status
                 (setf (proc-native-result proc) status)
                 (changed)))))
         *native-processes*)))))

(defun native-service-port ()
  (with-bsd
    (unless *native-port* (setf *native-port* (darterfly/worlds:make-port)))
    (unless (and *native-dispatcher*
                 (sb-thread:thread-alive-p *native-dispatcher*))
      (setf *native-dispatcher*
            (sb-thread:make-thread #'native-dispatch :name "native services")))
    *native-port*))

(defun native-fd (fd)
  (unless (<= 0 fd 4095) (fail :ebadf))
  fd)

(defun native-path (bytes)
  (unless (and (<= 1 (length bytes) +native-io-limit+)
               (eql (position 0 bytes) (1- (length bytes))))
    (fail :einval))
  (handler-case
      (sb-ext:octets-to-string bytes :end (1- (length bytes))
                                    :external-format :utf-8)
    (error () (fail :einval))))

(defun native-spawn-request (data search &key (native-only t))
  ;; Counts followed by NUL strings, then typed action records. No pointers.
  (unless (and (<= 24 (length data) +native-io-limit+) (<= search 1))
    (fail :einval))
  (let ((at 24) (argc (request-u64 data 0))
        (envc (request-u64 data 8)) (count (request-u64 data 16))
        (signals nil) (cloexec-default nil))
    (unless (and (<= argc 64) (<= envc 64) (<= count 65)) (fail :e2big))
    (labels ((string-next ()
               (let ((end (position 0 data :start at)))
                 (unless end (fail :einval))
                 (prog1 (native-path (subseq data at (1+ end)))
                   (setf at (1+ end))))))
      (let* ((path (string-next)) (search-path (string-next))
             (argv (loop repeat argc collect (string-next)))
             (envp (loop repeat envc collect (string-next)))
             (actions
               (loop repeat count collect
                 (progn
                   (unless (<= (+ at 32) (length data)) (fail :einval))
                   (let ((op (request-u64 data at))
                         (a (request-u64 data (+ at 8)))
                         (b (request-u64 data (+ at 16)))
                         (c (request-u64 data (+ at 24))))
                     (incf at 32)
                     (case op
                       (1 (list :dup2 (native-fd a) (native-fd b)))
                       (2 (list :close (native-fd a)))
                       (3 (unless (<= a 4096) (fail :ebadf))
                          (list :closefrom a))
                       (4 (unless (and (<= c #o7777)
                                       (zerop (logandc2 b #o207703))
                                       (/= (logand b 3) 3)) (fail :einval))
                          (list :open (native-fd a) (string-next)
                                (from-libsa-flags b) c))
                       (5 (list :chdir (string-next)))
                       (6 (when (or signals (> c 1)) (fail :einval))
                          (setf cloexec-default (= c 1))
                          (setf signals (list a b))
                          nil)
                       (t (fail :einval))))))))
        (unless (= at (length data)) (fail :einval))
        (when (> (length (remove nil actions)) 64) (fail :e2big))
        (posix-spawn path argv envp :file-actions (remove nil actions)
                     :native-only native-only :native-signals signals
                     :cloexec-default cloexec-default
                     :search-path (when (= search 1) search-path))))))

(defun native-wait-status (status)
  ;; BSD reports stay internal; the C headers and SBCL use Linux wait words.
  (flet ((signal-number (number)
           ;; SIGEMT and SIGINFO have no target equivalent: report SIGABRT.
           (or (aref #(0 1 2 3 4 5 6 nil 8 9 7 11 31 13 14 15
                       23 19 20 18 17 21 22 29 24 25 26 27 28 nil 10 12)
                     number)
               6)))
    (cond ((null status) nil)
          ((wifcontinued status) #xffff)
          ((wifstopped status) (logior #x7f (ash (signal-number (wstopsig status)) 8)))
          ((wifsignaled status)
           (logior (logand status #x80) (signal-number (wtermsig status))))
          (t status))))

(defun native-wait (pid options)
  (unless (or (= pid -1) (<= 1 pid +pid-max+)) (fail :einval))
  (unless (zerop (logandc2 options 11)) (fail :einval))
  (multiple-value-bind (child status)
      (wait4 pid :nohang (logbitp 0 options) :untraced (logbitp 1 options)
                 :continued (logbitp 3 options))
    (values child (native-wait-status status))))

(defun run-native-program (image argv envp)
  ;; A blocking poll/read must not hold up a different native thread's write.
  ;; Reuse bounded request workers; all mutations still use the BSD lock.
  (let ((proc *proc*) (world nil) (workers nil) (busy 0) (closing nil))
    (labels ((worker ()
               (let ((*proc* proc) (darterfly/mach:*task* (proc-task proc)))
                 (loop
                   (let ((request
                           (with-bsd
                             (loop
                               (when closing (return-from worker nil))
                               (when (proc-native-requests proc)
                                 (incf busy)
                                 (return (pop (proc-native-requests proc))))
                               (sb-thread:condition-wait *changed* *bsd*)))))
                     (unwind-protect
                          (native-reply-token
                           (car request)
                           (with-bsd
                             (serve-request proc (cdr request) (car request))))
                       (with-bsd (decf busy) (changed))))))))
      (unwind-protect
           (progn
             (with-bsd
               (setf world (darterfly/worlds:spawn-native-image
                            image :argv argv :envp envp :port (native-service-port)
                            :signals (proc-native-signals proc))
                     (proc-native-world proc) world
                     (proc-native-result proc) nil
                     (gethash world *native-processes*) proc))
             (loop
               (with-bsd
                 (deliver proc)
                 (when (proc-native-result proc)
                   (throw proc (proc-native-result proc)))
                 (when (and (proc-native-requests proc)
                            (= busy (length workers)))
                   (if (< (length workers) 64)
                       (push (sb-thread:make-thread #'worker
                               :name "native request") workers)
                       ;; Resource exhaustion must return an error instead
                       ;; of deadlocking every caller behind blocked polls.
                       (let ((request (pop (proc-native-requests proc))))
                         (native-reply-token
                          (car request)
                          (reply-octets -11 '(0 0 0 0) #() '(0 0 0 0))))))
                 (changed)
                 (sb-thread:condition-wait *changed* *bsd* :timeout 0.01))))
        (when world
          (with-bsd
            (setf closing t)
            (remhash world *native-processes*)
            (unless (proc-native-result proc)
              (darterfly/worlds:stop world)
              (setf (proc-native-result proc)
                    (darterfly/worlds:wait-native world)))
            (dolist (request (proc-native-requests proc))
              (native-reply-token
               (car request) (reply-octets -4 '(0 0 0 0) #() '(0 0 0 0))))
            (setf (proc-native-requests proc) nil)
            (changed))
          ;; Wake blocking operations before reclaiming descriptor tables.
          (dolist (thread workers)
            (unless (sb-thread:join-thread thread :default nil :timeout 1)
              (when (sb-thread:thread-alive-p thread)
                (sb-thread:terminate-thread thread)
                (sb-thread:join-thread thread :default nil))))
          (with-bsd (setf (proc-native-world proc) nil)))))))

(defun reset-native-services ()
  ;; Kernel rights and thread handles from a saved Lisp image are not valid
  ;; after boot (or when that image is used to start another Lisp world).
  (setf *native-port* nil
        *native-dispatcher* nil
        *native-processes* (make-hash-table)))

(pushnew 'reset-native-services sb-ext:*init-hooks*)

(defun native-kill (pid signal)
  (unless (<= 0 signal 64) (fail :einval))
  (let ((bsd (position signal #(0 1 2 3 4 5 6 nil 8 9 7 11 31 13 14 15
                               23 19 20 18 17 21 22 29 24 25 26 27 28 nil 10 12))))
    (unless bsd (fail :einval))
    (kill pid bsd)))
