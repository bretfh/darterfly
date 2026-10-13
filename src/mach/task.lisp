(in-package #:finch/mach)

(defclass thread ()
  ((port :reader thread-port)))

(defmethod initialize-instance :after ((thread thread) &key)
  (setf (slot-value thread 'port) (kernel-port thread)))

(defvar *threads* (make-hash-table :test 'eq :weakness :key :synchronized t))

(defun current-thread ()
  (or (gethash sb-thread:*current-thread* *threads*)
      (setf (gethash sb-thread:*current-thread* *threads*) (make-instance 'thread))))

(defun copy-send (port)
  (incf (srights port))
  (cons port :send))

(defun mach-task-self ()
  (with-ipc
    (let ((port (task-port *task*)))
      (or (gethash port (names *task*))
          (copyout *task* (copy-send port))))))

(defun mach-thread-self ()
  (with-ipc
    (copyout *task* (copy-send (thread-port (current-thread))))))

(defun mach-reply-port ()
  (mach-port-allocate *task* :receive))

(defun task-get-special-port (task which)
  (with-ipc
    (setf task (ipc-space task))
    (let ((carried (ecase which
                     (:kernel (copy-send (task-port task)))
                     (:bootstrap (and (bootstrap task) (copy-send (car (bootstrap task))))))))
      (and carried (copyout *task* carried)))))

(defun task-set-special-port (task which name)
  (with-ipc
    (setf task (ipc-space task))
    (unless (eq which :bootstrap) (fail :kern-invalid-argument))
    (let ((carried (and (valid-name-p name) (copyin *task* name :copy-send))))
      (let ((old (shiftf (bootstrap task) carried)))
        (when old (release old))))
    (values)))

(defun mach-ports-register (task &rest names)
  (with-ipc
    (setf task (ipc-space task))
    (when (> (length names) 3) (fail :kern-invalid-argument))
    (let ((new (loop :for i :below 3
                     :for name := (nth i names)
                     :collect (and (valid-name-p name) (copyin *task* name :copy-send)))))
      (mapc (lambda (old) (when old (release old))) (shiftf (registered task) new)))
    (values)))

(defun mach-ports-lookup (task)
  (with-ipc
    (setf task (ipc-space task))
    (mapcar (lambda (carried) (and carried (copyout *task* (copy-send (car carried)))))
            (registered task))))

(defun task-create (parent &optional name)
  (with-ipc
    (setf parent (ipc-space parent))
    (let ((task (make-task name)))
      (flet ((inherit (carried) (and carried (copy-send (car carried)))))
        (setf (bootstrap task) (inherit (bootstrap parent))
              (registered task) (mapcar #'inherit (registered parent))))
      task)))

(defun task-terminate (task)
  (with-ipc
    (setf task (ipc-space task))
    (loop :for name :in (sort (loop :for name :being :the :hash-keys :of (entries task) :collect name) #'<)
          :for e := (gethash name (entries task))
          :when e
            :do (let ((notify (request e)))
                  (when (consp notify)
                    (setf (request e) nil
                          (requests (object e)) (remove e (requests (object e)) :key #'car))
                    (notify notify +mach-notify-port-deleted+ name)))
                (remhash name (entries task))
                (remhash (object e) (names task))
                (dolist (right (rights e))
                  (ecase right
                    (:receive (kill (object e)))
                    (:send (lose-send (object e)))
                    (:send-once (release (cons (object e) :send-once)))
                    (:dead-name)
                    (:port-set
                     (dolist (port (members (object e)))
                       (setf (port-set port) nil))
                     (setf (members (object e)) nil)))))
    (when (bootstrap task) (release (shiftf (bootstrap task) nil)))
    (mapc (lambda (carried) (when carried (release carried))) (shiftf (registered task) (list nil nil nil)))
    (kill (task-port task))
    (values)))
