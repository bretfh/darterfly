(in-package #:finch/mach)

(defconstant +mach-port-qlimit-default+ 5)

(defvar *ipc* (sb-thread:make-mutex :name "ipc"))

(defmacro with-ipc (&body body)
  `(sb-thread:with-recursive-lock (*ipc*) ,@body))

(defun broadcast (queue)
  (sb-thread:condition-broadcast queue))

(defclass port ()
  ((receiver :initform nil :accessor receiver)
   (messages :initform nil :accessor messages)
   (qlimit :initform +mach-port-qlimit-default+ :accessor qlimit)
   (port-set :initform nil :accessor port-set)
   (deadp :initform nil :accessor deadp)
   (srights :initform 0 :accessor srights)
   (sorights :initform 0 :accessor sorights)
   (mscount :initform 0 :accessor mscount)
   (arrived :initform (sb-thread:make-waitqueue) :reader arrived)
   (drained :initform (sb-thread:make-waitqueue) :reader drained)))

(defclass port-set ()
  ((members :initform nil :accessor members)
   (arrived :initform (sb-thread:make-waitqueue) :reader arrived)))

(defclass entry ()
  ((object :initarg :object :reader object)
   (rights :initarg :rights :accessor rights)
   (urefs :initarg :urefs :accessor urefs)))

(defclass task ()
  ((name :initarg :name :initform nil :reader task-name)
   (entries :initform (make-hash-table) :reader entries)
   (names :initform (make-hash-table :test 'eq) :reader names)
   (next :initform 0 :accessor next)))

(defmethod print-object ((task task) stream)
  (print-unreadable-object (task stream :type t :identity t)
    (format stream "~@[~a~]" (task-name task))))

(defun make-task (&optional name)
  (make-instance 'task :name name))

(defvar *task* (make-task "self"))

(defun mach-task-self ()
  *task*)

(defun fresh-name (task)
  (loop :for name := (logior (ash (incf (next task)) 8) 3)
        :unless (gethash name (entries task)) :return name))

(defun enter (task object rights urefs &optional name)
  (let ((name (or name (fresh-name task))))
    (when (gethash name (entries task))
      (fail :kern-name-exists))
    (setf (gethash name (entries task))
          (make-instance 'entry :object object :rights rights :urefs urefs))
    (unless (equal rights '(:send-once))
      (setf (gethash object (names task)) name))
    name))

(defun check (e)
  (let ((port (object e)))
    (when (and (typep port 'port) (deadp port)
               (intersection '(:send :send-once) (rights e)))
      (setf (urefs e) (if (member :send-once (rights e)) 1 (urefs e))
            (rights e) (list :dead-name))))
  e)

(defun entry (task name &optional (absent :kern-invalid-name))
  (let ((e (and name (gethash name (entries task)))))
    (unless e (fail absent))
    (check e)))

(defun drop (task name e right)
  (setf (rights e) (remove right (rights e)))
  (when (null (rights e))
    (remhash name (entries task))
    (when (eql (gethash (object e) (names task)) name)
      (remhash (object e) (names task)))))

(defun leave-set (port)
  (let ((set (port-set port)))
    (when set
      (setf (members set) (remove port (members set))
            (port-set port) nil))))

(defun kill (port)
  (unless (deadp port)
    (setf (deadp port) t
          (receiver port) nil)
    (leave-set port)
    (let ((queued (messages port)))
      (setf (messages port) nil)
      (mapc #'discard queued))
    (broadcast (arrived port))
    (broadcast (drained port))))

(defconstant +mach-notify-send-once+ #o107)

(defun release (carried)
  (destructuring-bind (port . type) carried
    (ecase type
      (:receive (kill port))
      (:send (decf (srights port)))
      (:send-once
       (if (deadp port)
           (decf (sorights port))
           (enqueue port (make-kmsg :dest carried :id +mach-notify-send-once+)))))))

(defun consume (carried)
  (destructuring-bind (port . type) carried
    (ecase type
      (:send (decf (srights port)))
      (:send-once (decf (sorights port))))))

(defun copyin (task name disposition &key (absent :kern-invalid-name)
                                          (wrong :kern-invalid-right) dry)
  (let* ((e (entry task name absent))
         (port (object e)))
    (flet ((need (right)
             (unless (member right (rights e))
               (fail wrong))))
      (ecase disposition
        (:make-send
         (need :receive)
         (unless dry (incf (mscount port)) (incf (srights port)))
         (cons port :send))
        (:make-send-once
         (need :receive)
         (unless dry (incf (sorights port)))
         (cons port :send-once))
        (:copy-send
         (need :send)
         (unless dry (incf (srights port)))
         (cons port :send))
        (:move-send
         (need :send)
         (unless (or dry (plusp (decf (urefs e))))
           (drop task name e :send))
         (cons port :send))
        (:move-send-once
         (need :send-once)
         (unless dry (drop task name e :send-once))
         (cons port :send-once))
        (:move-receive
         (need :receive)
         (unless dry
           (leave-set port)
           (setf (receiver port) nil)
           (drop task name e :receive))
         (cons port :receive))))))

(defun copyout (task carried &optional name)
  (destructuring-bind (port . type) carried
    (let* ((have (gethash port (names task)))
           (e (and have (check (gethash have (entries task))))))
      (when (and name have (/= name have) (not (eq type :send-once)))
        (fail :kern-right-exists))
      (ecase type
        (:receive
         (setf (receiver port) task)
         (cond (e (push :receive (rights e)) have)
               (t (enter task port (list :receive) 0 name))))
        (:send
         (cond ((null e)
                (enter task port (list (if (deadp port) :dead-name :send)) 1 name))
               ((member :dead-name (rights e))
                (incf (urefs e))
                have)
               ((member :send (rights e))
                (decf (srights port))
                (incf (urefs e))
                have)
               (t
                (push :send (rights e))
                (setf (urefs e) 1)
                have)))
        (:send-once
         (enter task port (list (if (deadp port) :dead-name :send-once)) 1 name))))))

(defun mach-port-allocate (task right)
  (with-ipc
    (ecase right
      (:receive
       (let ((port (make-instance 'port)))
         (setf (receiver port) task)
         (enter task port (list :receive) 0)))
      (:port-set
       (enter task (make-instance 'port-set) (list :port-set) 0))
      (:dead-name
       (let ((port (make-instance 'port)))
         (setf (deadp port) t)
         (enter task port (list :dead-name) 1))))))

(defun mach-port-insert-right (task name poly disposition)
  (with-ipc
    (let ((carried (copyin *task* poly disposition)))
      (handler-bind ((kern-return (lambda (c) (declare (ignore c)) (release carried))))
        (copyout task carried name)))
    (values)))

(defun mach-port-deallocate (task name)
  (with-ipc
    (let* ((e (entry task name))
           (port (object e)))
      (cond ((member :send (rights e))
             (unless (plusp (decf (urefs e)))
               (decf (srights port))
               (drop task name e :send)))
            ((member :send-once (rights e))
             (drop task name e :send-once)
             (release (cons port :send-once)))
            ((member :dead-name (rights e))
             (unless (plusp (decf (urefs e)))
               (drop task name e :dead-name)))
            (t (fail :kern-invalid-right))))
    (values)))

(defun mach-port-mod-refs (task name right delta)
  (with-ipc
    (let* ((e (entry task name))
           (object (object e)))
      (unless (member right (rights e))
        (fail :kern-invalid-right))
      (ecase right
        ((:send :dead-name)
         (let ((urefs (+ (urefs e) delta)))
           (when (minusp urefs) (fail :kern-invalid-value))
           (setf (urefs e) urefs)
           (when (zerop urefs)
             (when (eq right :send) (decf (srights object)))
             (drop task name e right))))
        (:send-once
         (unless (member delta '(0 -1)) (fail :kern-invalid-value))
         (when (= delta -1)
           (drop task name e :send-once)
           (release (cons object :send-once))))
        (:receive
         (unless (member delta '(0 -1)) (fail :kern-invalid-value))
         (when (= delta -1)
           (drop task name e :receive)
           (kill object)))
        (:port-set
         (unless (member delta '(0 -1)) (fail :kern-invalid-value))
         (when (= delta -1)
           (dolist (port (members object))
             (setf (port-set port) nil)
             (broadcast (arrived port)))
           (setf (members object) nil)
           (broadcast (arrived object))
           (drop task name e :port-set)))))
    (values)))

(defun mach-port-destroy (task name)
  (with-ipc
    (entry task name)
    (dolist (right '(:send :send-once :dead-name :receive :port-set))
      (let ((e (gethash name (entries task))))
        (when (and e (member right (rights (check e))))
          (mach-port-mod-refs task name right
                              (if (member right '(:send :dead-name)) (- (urefs e)) -1)))))
    (values)))

(defun mach-port-type (task name)
  (with-ipc
    (copy-list (rights (entry task name)))))

(defun mach-port-get-refs (task name right)
  (with-ipc
    (let ((e (entry task name)))
      (cond ((not (member right (rights e))) 0)
            ((member right '(:send :dead-name)) (urefs e))
            (t 1)))))

(defun mach-port-names (task)
  (with-ipc
    (sort (loop :for name :being :the :hash-keys :of (entries task) :collect name) #'<)))

(defun mach-port-move-member (task member set)
  (with-ipc
    (let* ((e (entry task member))
           (port (object e)))
      (unless (member :receive (rights e))
        (fail :kern-invalid-right))
      (let ((target (and set (entry task set))))
        (when (and target (not (member :port-set (rights target))))
          (fail :kern-invalid-right))
        (leave-set port)
        (when target
          (let ((ps (object target)))
            (setf (port-set port) ps
                  (members ps) (append (members ps) (list port)))
            (when (messages port) (broadcast (arrived ps))))))
      (broadcast (arrived port)))
    (values)))
