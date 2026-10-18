(in-package #:darterfly/bsd)

;; One receive right for all BSD native children. Kernel-supplied sender IDs,
;; never a PID in the request, select the owning BSD descriptor table.
(defconstant +native-service-magic+ #x3156534e4644)
(defconstant +native-io-limit+ 4096)
(defvar *native-port* nil)
(defvar *native-dispatcher* nil)
(defvar *native-processes* (make-hash-table))

(defun native-put (bytes at value &optional (size 8))
  (dotimes (i size)
    (setf (aref bytes (+ at i)) (ldb (byte 8 (* 8 i)) value)))
  bytes)

(defun native-reply (result &optional (data #()))
  (let ((out (make-array (+ 8 (length data)) :element-type '(unsigned-byte 8))))
    (native-put out 0 result)
    (replace out data :start1 8)
    out))

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
              (unless queued (native-reply-token token (native-reply -4)))))
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

(defun native-new-fd (fd)
  (when (> fd 4095) (close fd) (fail :emfile))
  fd)

(defun native-path (bytes)
  (unless (and (<= 1 (length bytes) +native-io-limit+)
               (eql (position 0 bytes) (1- (length bytes))))
    (fail :einval))
  (handler-case
      (sb-ext:octets-to-string bytes :end (1- (length bytes))
                                    :external-format :utf-8)
    (error () (fail :einval))))

(defun native-spawn-request (data search)
  ;; Counts followed by NUL strings, then typed action records. No pointers.
  (unless (and (<= 24 (length data) +native-io-limit+) (<= search 1))
    (fail :einval))
  (let ((at 24) (argc (request-u64 data 0))
        (envc (request-u64 data 8)) (count (request-u64 data 16)))
    (unless (and (<= argc 64) (<= envc 64) (<= count 64)) (fail :e2big))
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
                       (t (fail :einval))))))))
        (unless (= at (length data)) (fail :einval))
        (posix-spawn path argv envp :file-actions actions :native-only t
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

(defun native-service-request (message)
  "Bounded, pointer-free service ABI for the initial single-threaded libc."
  (handler-case
      (progn
        (when (or (proc-closing *proc*) (eq (proc-state *proc*) :zombie))
          (fail :eintr))
        (unless (and (<= 32 (length message) (+ 32 +native-io-limit+))
                     (= (request-u64 message 0) +native-service-magic+))
          (fail :einval))
        (let* ((op (request-u64 message 8))
               (a (request-u64 message 16)) (b (request-u64 message 24))
               (data (subseq message 32)) (size (length data)))
          (flet ((empty () (unless (zerop size) (fail :einval)))
                 (word () (unless (= size 8) (fail :einval))
                          (request-u64 data 0)))
            (case op
              (1 ; open: flags, mode, NUL-terminated pathname
               (unless (and (<= b #o7777)
                            (zerop (logandc2 a #o2207703))
                            (/= (logand a 3) 3)) (fail :einval))
               (let ((fd (native-new-fd
                          (open (native-path data) (from-libsa-flags a) b))))
                 (when (logtest a #o2000000)
                   (setf (cdr (aref (proc-fds *proc*) fd)) t))
                 (native-reply fd)))
              (2 (empty) (native-reply (close (native-fd a))))
              (3 (empty)
                 (unless (<= b +native-io-limit+) (fail :einval))
                 (fd-file (native-fd a))
                 (let ((bytes (if (zerop b) #() (read a b))))
                   (native-reply (length bytes) bytes)))
              (4 (native-reply (write (native-fd a) data)))
              (5 (let ((whence (word)))
                   (unless (<= whence 2) (fail :einval))
                   (native-reply (lseek (native-fd a) (signed b)
                                        (nth whence '(:set :cur :end))))))
              (6 (empty) (native-reply (native-new-fd (dup (native-fd a)))))
              (7 (empty) (native-reply (dup2 (native-fd a) (native-fd b))))
              (8 (let ((arg (word)) (file (fd-file (native-fd a))))
                   (native-reply
                    (case b
                      (0 (native-new-fd (dup-from a (native-fd arg))))
                      (1 (if (cdr (aref (proc-fds *proc*) a)) 1 0))
                      (2 (setf (cdr (aref (proc-fds *proc*) a))
                               (logbitp 0 arg)) 0)
                      (3 (logior (file-access file)
                                 (if (nonblocking-p file) #o4000 0)))
                      (4 (setf (file-flags file)
                               (if (logtest arg #o4000) +o-nonblock+ 0)) 0)
                      (t (fail :einval))))))
              (9 (empty)
                 (unless (<= 1 a +native-io-limit+) (fail :erange))
                 (let ((bytes (sb-ext:string-to-octets
                               (getcwd) :external-format :utf-8
                                        :null-terminate t)))
                   (when (> (length bytes) a) (fail :erange))
                   (native-reply 0 bytes)))
              (10 (native-reply (chdir (native-path data))))
              (11 (unless (and (<= a 256) (= size (* a 8))) (fail :einval))
                  (let* ((entries
                           (loop for at from 0 below size by 8
                                 for fd = (request-u32 data at)
                                 collect (list (if (logbitp 31 fd)
                                                   (- fd (ash 1 32)) fd)
                                               (+ (aref data (+ at 4))
                                                  (ash (aref data (+ at 5)) 8)))))
                         (events (poll-fds entries (signed b))))
                    (loop for event in events for at from 6 by 8 do
                      (native-put data at event 2))
                    (native-reply (count-if #'plusp events) data)))
              (12 (empty) (native-reply (getpid)))
              (13 (empty) (native-reply (getppid)))
              (14 (empty)
                  (multiple-value-bind (rd wr) (pipe)
                    (when (or (> rd 4095) (> wr 4095))
                      (close rd) (close wr) (fail :emfile))
                    (let ((out (make-array 8 :element-type '(unsigned-byte 8))))
                      (native-put out 0 rd 4) (native-put out 4 wr 4)
                      (native-reply 0 out))))
              (15 (unless (zerop b) (fail :einval))
                  (native-reply (native-spawn-request data a)))
              (16 (empty)
                  (multiple-value-bind (pid status) (native-wait (signed a) b)
                    (let ((out (make-array 8 :element-type '(unsigned-byte 8))))
                      (native-put out 0 (or status 0))
                      (native-reply pid out))))
              (t (fail :enosys))))))
    (errno (e) (native-reply (- (vfs:errno-code (errno-name e)))))
    (vfs:vfs-error (e) (native-reply (- (vfs:errno-code (vfs:vfs-errno e)))))))

(defun run-native-program (image argv envp)
  (let ((proc *proc*) (world nil))
    (unwind-protect
         (progn
           (with-bsd
             (setf world (darterfly/worlds:spawn-native-image
                          image :argv argv :envp envp :port (native-service-port))
                   (proc-native-world proc) world
                   (proc-native-result proc) nil
                   (gethash world *native-processes*) proc))
           (loop
             (let ((request
                     (with-bsd
                       (deliver proc)
                       (when (proc-native-result proc)
                         (throw proc (proc-native-result proc)))
                       (or (pop (proc-native-requests proc))
                           (progn
                             (sb-thread:condition-wait *changed* *bsd*
                                                       :timeout 0.01)
                             nil)))))
               (when request
                 (native-reply-token
                  (car request)
                  (with-bsd (native-service-request (cdr request))))))))
      (when world
        (sb-sys:without-interrupts
          (with-bsd
            (remhash world *native-processes*)
            (unless (proc-native-result proc)
              (darterfly/worlds:stop world)
              (darterfly/worlds:wait-native world))
            (dolist (request (proc-native-requests proc))
              (native-reply-token (car request) (native-reply -4)))
            (setf (proc-native-world proc) nil
                  (proc-native-requests proc) nil)))))))

(defun reset-native-services ()
  ;; Kernel rights and thread handles from a saved Lisp image are not valid
  ;; after boot (or when that image is used to start another Lisp world).
  (setf *native-port* nil
        *native-dispatcher* nil
        *native-processes* (make-hash-table)))

(pushnew 'reset-native-services sb-ext:*init-hooks*)
