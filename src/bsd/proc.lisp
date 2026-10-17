(in-package #:finch/bsd)

(defvar *bsd* (sb-thread:make-mutex :name "bsd"))
(defvar *changed* (sb-thread:make-waitqueue))

(defmacro with-bsd (&body body)
  `(sb-thread:with-recursive-lock (*bsd*) ,@body))

(defun changed ()
  (sb-thread:condition-broadcast *changed*))

(defclass proc ()
  ((pid :initarg :pid :reader proc-pid)
   (parent :initarg :parent :initform nil :accessor proc-parent)
   (children :initform nil :accessor proc-children)
   (task :initarg :task :reader proc-task)
   (thread :initform nil :accessor proc-thread)
   (state :initform :run :accessor proc-state)
   (status :initform 0 :accessor proc-status)
   (report :initform nil :accessor proc-report)
   (fds :initform (make-array 0 :adjustable t :fill-pointer 0) :accessor proc-fds)
   (actions :initform (make-array 32 :initial-element :default) :reader proc-actions)
   (mask :initform 0 :accessor proc-mask)
   (pending :initform 0 :accessor proc-pending)
   (in-syscall :initform 0 :accessor in-syscall)
   (cwd :initform "/" :accessor proc-cwd)
   (root :initform "/" :accessor proc-root)
   (exec-tag :initform (list :exec) :reader exec-tag)
   (comm :initform "kernel" :accessor proc-comm)
   (path :initform nil :accessor proc-path)
   (threads :initform nil :accessor proc-threads)
   (bindings :initform nil :accessor proc-bindings)))

(defmethod print-object ((proc proc) stream)
  (print-unreadable-object (proc stream :type t)
    (format stream "~d ~(~a~)" (proc-pid proc) (proc-state proc))))

(defconstant +pid-max+ 99999)

(defvar *procs* (make-hash-table))
(defvar *next-pid* 0)
(defvar *proc0* (setf (gethash 0 *procs*) (make-instance 'proc :pid 0 :task finch/mach:*task*)))
(defvar *proc* *proc0*)

(defun next-pid ()
  (loop (setf *next-pid* (if (>= *next-pid* +pid-max+) 100 (1+ *next-pid*)))
        (unless (gethash *next-pid* *procs*) (return *next-pid*))))

(defun pfind (pid)
  (let ((proc (gethash pid *procs*)))
    (and proc (not (eq (proc-state proc) :zombie)) proc)))

(defun procs ()
  (with-bsd
    (sort (loop :for proc :being :the :hash-values :of *procs*
                :unless (eq (proc-state proc) :zombie) :collect proc)
          #'< :key #'proc-pid)))

(defun sigmask (signo) (ash 1 (1- signo)))

(defparameter +unmaskable+ (logior (sigmask 9) (sigmask 17)))

(defun deliverable (proc)
  (logand (proc-pending proc) (logior (lognot (proc-mask proc)) +unmaskable+)))

(defun deliver (proc)
  (let ((handled nil))
    (unless (eq proc *proc0*)
      (loop
        (let ((ready (deliverable proc)))
          (when (zerop ready) (return))
          (let ((signo (integer-length (logand ready (- ready)))))
            (setf (proc-pending proc) (logandc2 (proc-pending proc) (sigmask signo)))
            (let ((action (aref (proc-actions proc) signo)))
              (cond ((functionp action)
                     (let ((mask (proc-mask proc)))
                       (setf (proc-mask proc) (logior mask (sigmask signo)))
                       (unwind-protect (funcall action signo)
                         (setf (proc-mask proc) mask)))
                     (setf handled t))
                    ((eq action :ignore))
                    (t (ecase (default-action signo)
                         (:ignore)
                         (:term (throw proc (w-exitcode 0 signo)))
                         (:stop (stop proc signo))))))))))
    handled))

(defun stop (proc signo)
  (setf (proc-state proc) :stop
        (proc-report proc) (w-stopcode signo))
  (post (proc-parent proc) (signo :sigchld))
  (changed)
  (loop :while (and (eq (proc-state proc) :stop)
                    (not (logtest (proc-pending proc) (sigmask 9))))
        :do (sb-thread:condition-wait *changed* *bsd*)))

(defun post (proc signo)
  (when (and proc (not (eq (proc-state proc) :zombie)))
    (let ((name (signame signo)))
      (case name
        (:sigkill (when (eq (proc-state proc) :stop) (setf (proc-state proc) :run)))
        (:sigcont
         (setf (proc-pending proc)
               (logandc2 (proc-pending proc) (logior (sigmask 17) (sigmask 18) (sigmask 21) (sigmask 22))))
         (when (eq (proc-state proc) :stop)
           (setf (proc-state proc) :run
                 (proc-report proc) (w-stopcode +continued+))
           (post (proc-parent proc) (signo :sigchld))))
        ((:sigstop :sigtstp :sigttin :sigttou)
         (setf (proc-pending proc) (logandc2 (proc-pending proc) (sigmask 19)))))
      (let ((action (aref (proc-actions proc) signo)))
        (unless (or (eq action :ignore)
                    (and (eq action :default) (eq (default-action signo) :ignore)))
          (setf (proc-pending proc) (logior (proc-pending proc) (sigmask signo)))))
      (changed)
      (let ((thread (proc-thread proc)))
        (when (and thread (zerop (in-syscall proc)) (not (eq proc *proc*))
                   (plusp (deliverable proc)) (sb-thread:thread-alive-p thread))
          (sb-thread:interrupt-thread thread (lambda () (with-bsd (deliver proc)))))))))

(defmacro syscall (&body body)
  `(with-bsd
     (incf (in-syscall *proc*))
     (unwind-protect
          (multiple-value-prog1 (progn ,@body)
            (deliver *proc*))
       (decf (in-syscall *proc*)))))

(defun sleep-until (predicate)
  (loop
    (let ((value (funcall predicate)))
      (when value (return value)))
    (when (and (plusp (deliverable *proc*)) (deliver *proc*))
      (fail :eintr))
    (sb-thread:condition-wait *changed* *bsd*)
    (unless (sb-thread:holding-mutex-p *bsd*)
      (sb-thread:grab-mutex *bsd*))))

(defun getpid ()
  (proc-pid *proc*))

(defun getppid ()
  (let ((parent (proc-parent *proc*)))
    (if parent (proc-pid parent) 0)))

(defun proc-main (proc fn)
  (let ((*proc* proc)
        (finch/mach:*task* (proc-task proc)))
    (call-with-bindings (proc-bindings proc) (lambda () (proc-body proc fn)))))

(defun proc-body (proc fn)
  (let ((status (catch proc
                  (loop
                    (setf fn (catch (exec-tag proc)
                               (let ((code (handler-case (funcall fn)
                                             (error (e) (crash e)))))
                                 (return (w-exitcode (if (integerp code) (logand code 255) 0) 0)))))))))
    (proc-exit proc status)))

(defun crash (e)
  (ignore-errors (format *error-output* "~&~a[~d]: ~a~%" (proc-comm *proc*) (proc-pid *proc*) e)
                 (finish-output *error-output*))
  (throw *proc* (w-exitcode 0 (signo :sigabrt))))

(defun fork (fn)
  (with-bsd
    (let* ((parent *proc*)
           (child (make-instance 'proc :pid (next-pid) :parent parent
                                       :task (finch/mach:task-create (proc-task parent)))))
      (setf (gethash (proc-pid child) *procs*) child)
      (push child (proc-children parent))
      (loop :for slot :across (proc-fds parent)
            :do (when slot (incf (file-refs (car slot))))
                (vector-push-extend (and slot (cons (car slot) (cdr slot))) (proc-fds child)))
      (replace (proc-actions child) (proc-actions parent))
      (setf (proc-mask child) (proc-mask parent)
            (proc-cwd child) (proc-cwd parent)
            (proc-root child) (proc-root parent)
            (proc-comm child) (proc-comm parent)
            (proc-bindings child) (proc-bindings parent))
      (setf (proc-thread child)
            (sb-thread:make-thread (lambda () (proc-main child fn))
                                   :name (format nil "pid ~d" (proc-pid child))))
      (proc-pid child))))

(defun exit (code)
  (throw *proc* (w-exitcode (logand code 255) 0)))

(defun bsdthread-create (fn &optional (name "thread"))
  (let* ((proc *proc*)
         (task finch/mach:*task*)
         (bindings (proc-bindings proc))
         (thread (sb-thread:make-thread (lambda ()
                                          (let ((*proc* proc) (finch/mach:*task* task))
                                            (catch proc (call-with-bindings bindings fn))))
                                        :name name)))
    (with-bsd (push thread (proc-threads proc)))
    thread))

(defun proc-exit (proc status)
  (dolist (thread (with-bsd (shiftf (proc-threads proc) nil)))
    (unless (eq thread sb-thread:*current-thread*)
      (ignore-errors (sb-thread:terminate-thread thread))
      (ignore-errors (sb-thread:join-thread thread :default nil :timeout 1))))
  (with-bsd
    (loop :for fd :below (length (proc-fds proc))
          :when (aref (proc-fds proc) fd)
            :do (release-fd proc fd))
    (finch/mach:task-terminate (proc-task proc))
    (let ((init (or (pfind 1) *proc0*)))
      (dolist (child (proc-children proc))
        (setf (proc-parent child) init)
        (push child (proc-children init))))
    (setf (proc-children proc) nil
          (proc-state proc) :zombie
          (proc-status proc) status
          (proc-report proc) nil
          (proc-pending proc) 0)
    (post (proc-parent proc) (signo :sigchld))
    (changed)))

(defun wait4 (pid &key nohang untraced continued)
  (syscall
    (block wait
      (sleep-until
       (lambda ()
         (let ((children (remove-if-not (lambda (c) (or (= pid -1) (= (proc-pid c) pid)))
                                        (proc-children *proc*))))
           (unless children (fail :echild))
           (dolist (child children)
             (let ((report (proc-report child)))
               (cond ((eq (proc-state child) :zombie)
                      (setf (proc-children *proc*) (remove child (proc-children *proc*)))
                      (remhash (proc-pid child) *procs*)
                      (return-from wait (values (proc-pid child) (proc-status child))))
                     ((and report (or (and untraced (wifstopped report))
                                      (and continued (wifcontinued report))))
                      (setf (proc-report child) nil)
                      (return-from wait (values (proc-pid child) report))))))
           (when nohang (return-from wait (values 0 nil)))
           nil))))))

(defun kill (pid signal)
  (syscall
    (let ((signo (signo signal)))
      (unless (<= 0 signo 31) (fail :einval))
      (unless (plusp pid) (fail :einval))
      (let ((proc (pfind pid)))
        (unless proc (fail :esrch))
        (unless (zerop signo) (post proc signo))
        0))))

(defun pause ()
  (syscall (sleep-until (lambda () nil))))

(defun sigaction (signal action)
  (syscall
    (let ((signo (signo signal)))
      (when (or (not (< 0 signo 32)) (member signo '(9 17)))
        (fail :einval))
      (prog1 (aref (proc-actions *proc*) signo)
        (setf (aref (proc-actions *proc*) signo) action)
        (when (or (eq action :ignore)
                  (and (eq action :default) (eq (default-action signo) :ignore)))
          (setf (proc-pending *proc*) (logandc2 (proc-pending *proc*) (sigmask signo))))))))

(defun sigprocmask (how signals)
  (syscall
    (let ((set (logandc2 (reduce #'logior (mapcar (lambda (s) (sigmask (signo s))) signals)) +unmaskable+)))
      (prog1 (proc-mask *proc*)
        (setf (proc-mask *proc*)
              (ecase how
                (:block (logior (proc-mask *proc*) set))
                (:unblock (logandc2 (proc-mask *proc*) set))
                (:setmask set)))))))

(defun task-pid (task)
  (with-bsd
    (loop :for proc :being :the :hash-values :of *procs*
          :when (and (eq (proc-task proc) task) (not (eq (proc-state proc) :zombie)))
            :return (proc-pid proc))))

(defun forget-processes ()
  (setf *bsd* (sb-thread:make-mutex :name "bsd")
        *changed* (sb-thread:make-waitqueue)
        *procs* (make-hash-table)
        *next-pid* 0
        finch/mach:*task* (finch/mach:make-task "self")
        *proc0* (setf (gethash 0 *procs*) (make-instance 'proc :pid 0 :task finch/mach:*task*))
        *proc* *proc0*))

(pushnew 'forget-processes sb-ext:*save-hooks*)

(defun end-processes ()
  (dolist (proc (procs))
    (when (> (proc-pid proc) 0)
      (ignore-errors (kill (proc-pid proc) :sigkill))))
  (loop :repeat 100 :while (rest (procs)) :do (sleep 0.05)))
