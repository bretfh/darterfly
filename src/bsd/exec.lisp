(in-package #:finch/bsd)

(defvar *programs* (make-hash-table :test 'equal))
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
      (or (and (uiop:string-prefix-p "#!finch " line)
               (gethash (string-trim " " (subseq line 8)) *programs*))
          (fail :enoexec)))))

(defun basename (name)
  (subseq name (1+ (or (position #\/ name :from-end t) -1))))

(defun execve (name argv envp)
  (with-bsd
    (let ((program (program-of name))
          (proc *proc*))
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
          (lambda () (call-with-bindings bindings (lambda () (with-stdio (funcall program argv envp))))))))))

(defun posix-spawn (name argv envp &key file-actions)
  (with-bsd
    (program-of name)
    (fork (lambda ()
            (loop :for (action . args) :in file-actions
                  :do (ecase action
                        (:open (destructuring-bind (fd path flags &optional (mode #o644)) args
                                 (let ((new (open path flags mode)))
                                   (unless (= new fd) (dup2 new fd) (close new)))))
                        (:dup2 (apply #'dup2 args))
                        (:close (apply #'close args))
                        (:closefrom (loop :for fd :from (first args) :below (length (proc-fds *proc*))
                                          :when (aref (proc-fds *proc*) fd) :do (close fd)))
                        (:chdir (apply #'chdir args))))
            (execve name argv envp)))))

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
