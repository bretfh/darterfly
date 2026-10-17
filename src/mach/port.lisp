(in-package #:darterfly/mach)

(defconstant +mach-port-qlimit-default+ 5)
(defconstant +mach-port-qlimit-max+ 1024)
(defconstant +mach-port-dead+ #xffffffff)
(defconstant +mach-notify-port-deleted+ #o101)
(defconstant +mach-notify-send-possible+ #o102)
(defconstant +mach-notify-port-destroyed+ #o105)
(defconstant +mach-notify-no-senders+ #o106)
(defconstant +mach-notify-send-once+ #o107)
(defconstant +mach-notify-dead-name+ #o110)

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
   (nsrequest :initform nil :accessor nsrequest)
   (pdrequest :initform nil :accessor pdrequest)
   (requests :initform nil :accessor requests)
   (seqno :initform 0 :accessor seqno)
   (context :initform 0 :accessor context)
   (kobject :initform nil :accessor kobject)
   (arrived :initform (sb-thread:make-waitqueue) :reader arrived)
   (drained :initform (sb-thread:make-waitqueue) :reader drained)))

(defclass port-set ()
  ((members :initform nil :accessor members)
   (arrived :initform (sb-thread:make-waitqueue) :reader arrived)))

(defclass entry ()
  ((object :initarg :object :reader object)
   (rights :initarg :rights :accessor rights)
   (urefs :initarg :urefs :accessor urefs)
   (request :initform nil :accessor request)
   (armed :initform nil :accessor armed)))

(defclass task ()
  ((name :initarg :name :initform nil :reader task-name)
   (entries :initform (make-hash-table) :reader entries)
   (names :initform (make-hash-table :test 'eq) :reader names)
   (next :initform 0 :accessor next)
   (port :reader task-port)
   (bootstrap :initform nil :accessor bootstrap)
   (registered :initform (list nil nil nil) :accessor registered)))

(defmethod print-object ((task task) stream)
  (print-unreadable-object (task stream :type t :identity t)
    (format stream "~@[~a~]" (task-name task))))

(defun kernel-port (object)
  (let ((port (make-instance 'port)))
    (setf (kobject port) object
          (receiver port) :kernel)
    port))

(defmethod initialize-instance :after ((task task) &key)
  (setf (slot-value task 'port) (kernel-port task)))

(defun make-task (&optional name)
  (make-instance 'task :name name))

(defvar *task* (make-task "self"))

(defun valid-name-p (name)
  (and name (/= name 0) (/= name +mach-port-dead+)))

(defun ipc-space (task)
  (if (typep task 'task)
      task
      (let* ((e (and (valid-name-p task) (gethash task (entries *task*))))
             (port (and e (object (check e)))))
        (unless (and port (member :send (rights e)) (typep (kobject port) 'task))
          (fail :mach-send-invalid-dest))
        (kobject port))))

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
      (setf (urefs e) (+ (if (member :send-once (rights e)) 1 (urefs e))
                         (if (request e) 1 0))
            (rights e) (list :dead-name)
            (request e) nil)))
  e)

(defun entry (task name &optional (absent :kern-invalid-name))
  (let ((e (and name (gethash name (entries task)))))
    (unless e (fail absent))
    (check e)))

(defun drop (task name e right)
  (setf (rights e) (remove right (rights e)))
  (when (null (rights e))
    (let ((notify (request e)))
      (when (consp notify)
        (setf (request e) nil
              (armed e) nil
              (requests (object e)) (remove e (requests (object e)) :key #'car))
        (notify notify +mach-notify-port-deleted+ name)))
    (remhash name (entries task))
    (when (eql (gethash (object e) (names task)) name)
      (remhash (object e) (names task)))))

(defun leave-set (port)
  (let ((set (port-set port)))
    (when set
      (setf (members set) (remove port (members set))
            (port-set port) nil))))

(defun kill (port)
  (let ((pd (pdrequest port)))
    (cond ((deadp port))
          (pd
           (setf (pdrequest port) nil
                 (receiver port) nil)
           (leave-set port)
           (notify pd +mach-notify-port-destroyed+ nil (list (cons port :receive))))
          (t
           (setf (deadp port) t
                 (receiver port) nil)
           (leave-set port)
           (let ((queued (messages port)))
             (setf (messages port) nil)
             (mapc #'discard queued))
           (let ((ns (nsrequest port)))
             (setf (nsrequest port) nil)
             (when ns (release ns)))
           (loop :for (e . name) :in (shiftf (requests port) nil)
                 :for notify := (request e)
                 :when (consp notify)
                   :do (setf (request e) t
                             (armed e) nil)
                       (notify notify +mach-notify-dead-name+ name))
           (broadcast (arrived port))
           (broadcast (drained port))))))

(defun notify (carried id &optional body rights)
  (let ((port (car carried)))
    (if (deadp port)
        (progn (decf (sorights port)) (mapc #'release-descriptor rights))
        (enqueue port (make-kmsg :dest carried :id id :body body :rights rights)))))

(defun lose-send (port)
  (when (and (zerop (decf (srights port))) (nsrequest port) (not (deadp port)))
    (notify (shiftf (nsrequest port) nil) +mach-notify-no-senders+ (mscount port))))

(defun release (carried)
  (destructuring-bind (port . type) carried
    (when port
      (ecase type
        (:receive (kill port))
        (:send (lose-send port))
        (:send-once (notify carried +mach-notify-send-once+))))))

(defun release-descriptor (d)
  (typecase d
    ((cons simple-vector) (loop :for c :across (car d) :when c :do (release c)))
    (cons (release d))))

(defun send-possible (port)
  (when (< (length (messages port)) (qlimit port))
    (loop :for r :in (requests port)
          :for (e . name) := r
          :when (armed e)
            :do (setf (requests port) (remove r (requests port))
                      (armed e) nil)
                (notify (shiftf (request e) nil) +mach-notify-send-possible+ name))))

(defun consume (carried)
  (destructuring-bind (port . type) carried
    (ecase type
      (:send (lose-send port))
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
    (when (and (deadp port) (null name) (not (eq type :receive)))
      (consume carried)
      (return-from copyout +mach-port-dead+))
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
    (setf task (ipc-space task))
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

(defun mach-port-allocate-name (task right name)
  (with-ipc
    (setf task (ipc-space task))
    (unless (and (integerp name) (< 0 name #xffffffff)) (fail :kern-invalid-value))
    (case right
      (:receive
       (let ((port (make-instance 'port)))
         (prog1 (enter task port (list :receive) 0 name)
           (setf (receiver port) task))))
      (:port-set (enter task (make-instance 'port-set) (list :port-set) 0 name))
      (:dead-name name)
      (t (fail :kern-invalid-value)))))

(defun mach-port-insert-right (task name poly disposition)
  (with-ipc
    (setf task (ipc-space task))
    (let ((carried (copyin *task* poly disposition)))
      (handler-bind ((kern-return (lambda (c) (declare (ignore c)) (release carried))))
        (copyout task carried name)))
    (values)))

(defun mach-port-deallocate (task name)
  (with-ipc
    (setf task (ipc-space task))
    (let* ((e (entry task name))
           (port (object e)))
      (cond ((member :send (rights e))
             (unless (plusp (decf (urefs e)))
               (drop task name e :send)
               (lose-send port)))
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
    (setf task (ipc-space task))
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
             (drop task name e right)
             (when (eq right :send) (lose-send object)))))
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
    (setf task (ipc-space task))
    (entry task name)
    (dolist (right '(:send :send-once :dead-name :receive :port-set))
      (let ((e (gethash name (entries task))))
        (when (and e (member right (rights (check e))))
          (mach-port-mod-refs task name right
                              (if (member right '(:send :dead-name)) (- (urefs e)) -1)))))
    (values)))

(defun mach-port-type (task name)
  (with-ipc
    (setf task (ipc-space task))
    (if (eql name +mach-port-dead+)
        (list :dead-name)
        (copy-list (rights (entry task name))))))

(defun mach-port-get-refs (task name right)
  (with-ipc
    (setf task (ipc-space task))
    (unless (valid-name-p name)
      (if (member right '(:send :send-once))
          (return-from mach-port-get-refs 1)
          (fail :kern-invalid-name)))
    (let ((e (entry task name)))
      (cond ((not (member right (rights e))) 0)
            ((member right '(:send :dead-name)) (urefs e))
            (t 1)))))

(defun mach-port-names (task)
  (with-ipc
    (setf task (ipc-space task))
    (sort (loop :for name :being :the :hash-keys :of (entries task) :collect name) #'<)))

(defun mach-port-move-member (task member set)
  (with-ipc
    (setf task (ipc-space task))
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

(defun receive-port (task name)
  (let ((e (entry task name)))
    (unless (member :receive (rights e)) (fail :kern-invalid-right))
    (object e)))

(defun set-request (e name kind sync notify)
  (let* ((port (object e))
         (previous (and (consp (request e)) (request e))))
    (setf (requests port) (remove e (requests port) :key #'car)
          (request e) nil
          (armed e) nil)
    (cond ((null notify))
          ((and (eq kind :send-possible) (plusp sync)
                (or (member :send-once (rights e))
                    (< (length (messages port)) (qlimit port))))
           (notify notify +mach-notify-send-possible+ name))
          (t (setf (request e) notify
                   (armed e) (and (eq kind :send-possible) (plusp sync)))
             (push (cons e name) (requests port))))
    previous))

(defun request-notification (task name kind sync notify)
  (ecase kind
    (:port-destroyed
     (unless (zerop sync) (fail :kern-invalid-value))
     (setf (pdrequest (receive-port task name)) notify)
     nil)
    (:no-senders
     (let* ((port (receive-port task name))
            (previous (nsrequest port)))
       (if (and notify (zerop (srights port)) (<= sync (mscount port)))
           (progn (setf (nsrequest port) nil)
                  (notify notify +mach-notify-no-senders+ (mscount port)))
           (setf (nsrequest port) notify))
       previous))
    ((:dead-name :send-possible)
     (let ((e (entry task name)))
       (cond ((intersection '(:send :send-once :receive) (rights e))
              (set-request e name kind sync notify))
             ((and (member :dead-name (rights e)) (eq kind :send-possible) notify)
              (incf (urefs e))
              (notify notify +mach-notify-dead-name+ name)
              nil)
             ((member :dead-name (rights e)) (fail :kern-invalid-argument))
             (t (fail :kern-invalid-right)))))))

(defun mach-port-request-notification (task name kind sync notify disposition)
  (with-ipc
    (setf task (ipc-space task))
    (let ((carried (and notify (copyin *task* notify disposition
                                       :absent :mach-send-invalid-right
                                       :wrong :mach-send-invalid-right))))
      (let ((previous (handler-bind ((kern-return (lambda (c)
                                                    (declare (ignore c))
                                                    (when carried (release carried)))))
                        (unless (member kind '(:port-destroyed :no-senders :dead-name :send-possible))
                          (fail :kern-invalid-value))
                        (request-notification task name kind sync carried))))
        (and previous (copyout task previous))))))

(defun mach-port-get-attributes (task name flavor)
  (with-ipc
    (setf task (ipc-space task))
    (ecase flavor
      (:receive-status
       (let ((port (receive-port task name)))
         (list :seqno (seqno port) :mscount (mscount port) :qlimit (qlimit port)
               :msgcount (length (messages port)) :sorights (sorights port)
               :srights (if (plusp (srights port)) 1 0) :pdrequest (if (pdrequest port) 1 0)
               :nsrequest (if (nsrequest port) 1 0) :flags 0))))))

(defun mach-port-set-attributes (task name flavor value)
  (with-ipc
    (setf task (ipc-space task))
    (ecase flavor
      (:limits-info
       (let ((port (receive-port task name)))
         (unless (<= 0 value +mach-port-qlimit-max+) (fail :kern-invalid-value))
         (setf (qlimit port) value)
         (broadcast (drained port)))))
    (values)))

(defun mach-port-set-mscount (task name mscount)
  (with-ipc
    (setf task (ipc-space task))
    (setf (mscount (receive-port task name)) mscount)
    (values)))

(defun mach-port-set-seqno (task name seqno)
  (with-ipc
    (setf task (ipc-space task))
    (setf (seqno (receive-port task name)) seqno)
    (values)))

(defun mach-port-set-context (task name context)
  (with-ipc
    (setf task (ipc-space task))
    (setf (context (receive-port task name)) context)
    (values)))

(defun mach-port-get-context (task name)
  (with-ipc
    (setf task (ipc-space task))
    (context (receive-port task name))))

(defun mach-port-get-set-status (task name)
  (with-ipc
    (setf task (ipc-space task))
    (let ((e (entry task name)))
      (unless (member :port-set (rights e)) (fail :kern-invalid-right))
      (mapcar (lambda (port) (gethash port (names task))) (members (object e))))))

(defun mach-port-extract-right (task name disposition)
  (with-ipc
    (setf task (ipc-space task))
    (let ((carried (copyin task name disposition)))
      (values (copyout *task* carried) (moved (cdr carried))))))
