(in-package #:darterfly/bsd)

(defvar *programs* (make-hash-table :test 'equal))
(defvar *safe* nil)
(defvar *process-variables* nil)

(defmacro define-process-variable (name init)
  `(progn
     (defvar ,name nil)
     (setf *process-variables*
           (append (remove ',name *process-variables* :key #'car)
                   (list (cons ',name (lambda () ,init)))))
     ',name))

(defun fresh-bindings ()
  (cons (mapcar #'car *process-variables*)
        (mapcar (lambda (v) (funcall (cdr v))) *process-variables*)))

(defun call-with-bindings (bindings function)
  (if bindings
      (progv (car bindings) (cdr bindings) (funcall function))
      (funcall function)))

(defmacro define-program (name (argv envp) &body body)
  `(setf (gethash ,name *programs*) (lambda (,argv ,envp) (declare (ignorable ,argv ,envp)) ,@body)))

(defstruct native-program image)

(defconstant +s-ixall+ #o111)

(defun first-line (full)
  (vfs (let ((fd (vfs:vfs-open full (list :access :rdonly) 0)))
         (unwind-protect
              (let ((octets (vfs:vfs-read fd 256)))
                (map 'string #'code-char (subseq octets 0 (or (position 10 octets) (length octets)))))
           (vfs:vfs-close fd)))))

(defun program-of (name)
  (let* ((full (path name))
         (mode (vfs:vattr-mode (vfs (vfs:vfs-stat full)))))
    (unless (and (= (logand mode +s-ifmt+) +s-ifreg+) (logtest mode +s-ixall+))
      (fail :eacces))
    (let ((line (first-line full)))
      (or (and (>= (length line) 4)
               (equal (map 'list #'char-code (subseq line 0 4))
                      '(127 69 76 70))
               (handler-case
                   (make-native-program
                    :image (darterfly/worlds:read-native-image full))
                 (darterfly/worlds:world-error () (fail :enoexec))))
          (and (uiop:string-prefix-p "#!darterfly " line)
               (gethash (string-trim " " (subseq line (length "#!darterfly "))) *programs*))
          (fail :enoexec)))))

(defun basename (name)
  (subseq name (1+ (or (position #\/ name :from-end t) -1))))

(defun execve (name argv envp)
  (with-bsd (exec-program name argv envp (program-of name))))

(defun exec-program (name argv envp program)
  (with-bsd
    (let ((proc *proc*))
      (loop :for fd :below (length (proc-fds proc))
            :for slot := (aref (proc-fds proc) fd)
            :when (and slot (cdr slot)) :do (release-fd proc fd))
      (loop :for signo :from 1 :below 32
            :when (functionp (aref (proc-actions proc) signo))
              :do (setf (aref (proc-actions proc) signo) :default))
      (setf (proc-comm proc) (basename name)
            (proc-path proc) (path name))
      (let ((bindings (fresh-bindings)))
        (setf (proc-bindings proc) bindings)
        (throw (exec-tag proc)
          (lambda ()
            (call-with-bindings
             bindings
             (lambda ()
               (if (native-program-p program)
                   (run-native-program (native-program-image program) argv envp)
                   (with-stdio (funcall program argv envp)))))))))))

(defun spawn-file-actions (actions)
  (loop for (action . args) in actions do
    (ecase action
      (:open (destructuring-bind (fd path flags &optional (mode #o644)) args
               (unless (<= 0 fd 4095) (fail :ebadf))
               ;; OPEN replaces FD, even if it is already occupied.
               (when (and (< fd (length (proc-fds *proc*)))
                          (aref (proc-fds *proc*) fd)) (close fd))
               (let ((new (open path flags mode)))
                 (unless (= new fd) (dup2 new fd) (close new)))))
      (:dup2 (destructuring-bind (from to) args
               (dup2 from to)
               ;; POSIX spawn's dup2 action clears close-on-exec even for
               ;; identical descriptors (plain dup2 preserves it then).
               (setf (cdr (aref (proc-fds *proc*) to)) nil)))
      (:close (apply #'close args))
      (:closefrom (unless (<= 0 (first args) 4096) (fail :ebadf))
                  (loop for fd from (first args)
                        below (length (proc-fds *proc*))
                        when (aref (proc-fds *proc*) fd) do (close fd)))
      (:chdir (apply #'chdir args)))))

(defun posix-spawn (name argv envp &key file-actions)
  (let ((program nil))
    (fork (lambda () (exec-program name argv envp program))
          :prepare (lambda ()
                     (spawn-file-actions file-actions)
                     (setf program (program-of name))))))

(defvar *reboot* nil)

(defun reboot (how)
  (when *reboot* (funcall *reboot* how))
  (fail :eperm))

(define-process-variable *resume* nil)

(defvar *suspended* nil)

(defun suspend-processes ()
  (setf *suspended*
        (loop for proc in (procs)
              for thread = (proc-thread proc)
              for bindings = (proc-bindings proc)
              when (and bindings thread (sb-thread:thread-alive-p thread)
                        (not (uiop:string-prefix-p "/System/Library/Services/" (or (proc-path proc) "")))
                        (ignore-errors (sb-thread:symbol-value-in-thread '*resume* thread nil)))
                collect (list (proc-path proc) (proc-comm proc)
                              (cons (car bindings)
                                    (mapcar (lambda (symbol) (ignore-errors (sb-thread:symbol-value-in-thread symbol thread nil)))
                                            (car bindings)))))))

(defun resume-processes ()
  (when *safe* (return-from resume-processes nil))
  (dolist (entry (shiftf *suspended* nil))
    (destructuring-bind (path comm bindings) entry
      (ignore-errors
       (fork (lambda ()
               (with-bsd
                 (setf (proc-comm *proc*) comm
                       (proc-path *proc*) path
                       (proc-bindings *proc*) bindings))
               (throw (exec-tag *proc*)
                 (lambda () (call-with-bindings bindings (lambda () (with-stdio (funcall *resume*))))))))))))

(defvar *activities* nil)
(defvar *recording* nil)
(defvar *user-threads* (make-hash-table :test 'eq :weakness :key :synchronized t))
(defvar *threads-to-resume* nil)

(defmacro keep-running (key &body body)
  `(progn
     (setf *activities* (cons (cons ,key (lambda () ,@body)) (remove ,key *activities* :key #'car :test #'equal)))
     (let ((*recording* nil)) ,@body)))

(defun stop-keeping (key)
  (setf *activities* (remove key *activities* :key #'car :test #'equal)))

(defun record-user-thread (make-thread function &rest keys)
  (let ((thread (apply make-thread function keys)))
    (when *recording*
      (setf (gethash thread *user-threads*) (cons function keys)))
    thread))

(defvar *reloading* nil)
(defvar *reloaded* 0)

(defun reloading-p ()
  (or *reloading* (< (- (get-internal-real-time) *reloaded*) internal-time-units-per-second)))

(defun retry-restart (condition)
  (find "RETRY" (compute-restarts condition) :key (lambda (r) (symbol-name (restart-name r))) :test #'string=))

(defvar *background-errors* nil)

(defun note-background-error (condition)
  (let ((entry (list :time (get-universal-time)
                     :thread (sb-thread:thread-name sb-thread:*current-thread*)
                     :process (and *proc* (proc-comm *proc*))
                     :error (ignore-errors (princ-to-string condition))
                     :backtrace (ignore-errors (with-output-to-string (s) (sb-debug:print-backtrace :stream s :count 25))))))
    (sb-ext:atomic-push entry *background-errors*)
    (when (> (length *background-errors*) 50)
      (setf (cdr (nthcdr 49 *background-errors*)) nil))))

(defun report-and-unwind (condition hook)
  (declare (ignore hook))
  (unless (or (eq sb-thread:*current-thread* (sb-thread:main-thread)) *debugger-hook*)
    (when (reloading-p)
      (loop while *reloading* do (sleep 0.05))
      (let ((retry (retry-restart condition)))
        (when retry (invoke-restart retry))))
    (ignore-errors (note-background-error condition))
    (ignore-errors
     (format *error-output* "~&~a: ~a~%" (sb-thread:thread-name sb-thread:*current-thread*) condition)
     (sb-debug:print-backtrace :stream *error-output* :count 15))
    (abort)))

(sb-ext:without-package-locks
  (sb-int:unencapsulate 'sb-thread:make-thread 'user-threads)
  (sb-int:encapsulate 'sb-thread:make-thread 'user-threads #'record-user-thread))

(defun suspend-threads ()
  (setf *threads-to-resume*
        (loop for thread being the hash-keys of *user-threads* using (hash-value how)
              when (sb-thread:thread-alive-p thread) collect how)))

(defun resume-activities ()
  (when *safe* (return-from resume-activities nil))
  (dolist (activity (reverse *activities*))
    (handler-case (let ((*recording* nil)) (funcall (cdr activity)))
      (error (e) (format *error-output* "~&resume ~a: ~a~%" (car activity) e))))
  (dolist (how (shiftf *threads-to-resume* nil))
    (handler-case (let ((*recording* t)) (apply #'sb-thread:make-thread how))
      (error (e) (format *error-output* "~&resume thread: ~a~%" e)))))
