(in-package #:finch/mach)

(defclass message ()
  ((remote-port :initarg :remote-port :initform nil :accessor msgh-remote-port)
   (remote-disposition :initarg :remote-disposition :initform :copy-send
                       :accessor msgh-remote-disposition)
   (local-port :initarg :local-port :initform nil :accessor msgh-local-port)
   (local-disposition :initarg :local-disposition :initform :make-send-once
                      :accessor msgh-local-disposition)
   (id :initarg :id :initform 0 :accessor msgh-id)
   (body :initarg :body :initform nil :accessor msgh-body)
   (descriptors :initarg :descriptors :initform nil :accessor msgh-descriptors)
   (seqno :initarg :seqno :initform 0 :accessor msgh-seqno)))

(defmethod print-object ((m message) stream)
  (print-unreadable-object (m stream :type t)
    (format stream "~d -> ~@[#x~x~]~@[ reply #x~x~]" (msgh-id m)
            (msgh-remote-port m) (msgh-local-port m))))

(defun make-message (&rest initargs)
  (apply #'make-instance 'message initargs))

(defstruct kmsg dest reply id body rights)

(defun discard (kmsg)
  (release (kmsg-dest kmsg))
  (when (kmsg-reply kmsg) (release (kmsg-reply kmsg)))
  (mapc #'release-descriptor (kmsg-rights kmsg)))

(defun carried-type (disposition)
  (ecase disposition
    ((:make-send :copy-send :move-send) :send)
    ((:make-send-once :move-send-once) :send-once)
    (:move-receive :receive)))

(defun copyin-descriptor (task d dry)
  (flet ((one (name disposition)
           (if name
               (copyin task name disposition :absent :mach-send-invalid-right
                                             :wrong :mach-send-invalid-right :dry dry)
               (cons nil (carried-type disposition)))))
    (typecase d
      ((cons vector) (cons (map 'simple-vector (lambda (name) (and name (one name (cdr d)))) (car d))
                           (carried-type (cdr d))))
      (cons (one (car d) (cdr d)))
      (t (copy-seq d)))))

(defun copyout-descriptor (task d)
  (typecase d
    ((cons simple-vector) (cons (map 'simple-vector (lambda (c) (and c (copyout task c))) (car d))
                                (moved (cdr d))))
    (cons (cons (and (car d) (copyout task d)) (moved (cdr d))))
    (t d)))

(defun moved (type)
  (ecase type
    (:send :move-send)
    (:send-once :move-send-once)
    (:receive :move-receive)))

(defun copyin-message (task m dry)
  (unless (member (msgh-remote-disposition m)
                  '(:copy-send :make-send :move-send :make-send-once :move-send-once))
    (fail :mach-send-invalid-header))
  (when (and (msgh-local-port m) (eq (msgh-local-disposition m) :move-receive))
    (fail :mach-send-invalid-header))
  (make-kmsg
   :dest (copyin task (msgh-remote-port m) (msgh-remote-disposition m)
                 :absent :mach-send-invalid-dest :wrong :mach-send-invalid-dest :dry dry)
   :reply (and (msgh-local-port m)
               (copyin task (msgh-local-port m) (msgh-local-disposition m)
                       :absent :mach-send-invalid-reply :wrong :mach-send-invalid-reply
                       :dry dry))
   :id (msgh-id m)
   :body (msgh-body m)
   :rights (loop :for d :in (msgh-descriptors m) :collect (copyin-descriptor task d dry))))

(defun deadline (timeout)
  (and timeout
       (+ (get-internal-real-time)
          (round (* timeout internal-time-units-per-second) 1000))))

(defun wait (queue deadline)
  (let ((left (and deadline
                   (/ (- deadline (get-internal-real-time))
                      internal-time-units-per-second))))
    (unless (and left (<= left 0))
      (sb-thread:condition-wait queue *ipc* :timeout left)
      (unless (sb-thread:holding-mutex-p *ipc*)
        (sb-thread:grab-mutex *ipc*))
      t)))

(defun enqueue (port kmsg)
  (setf (messages port) (append (messages port) (list kmsg)))
  (broadcast (arrived port))
  (when (port-set port)
    (broadcast (arrived (port-set port)))))

(defun pseudo-receive (task k)
  (copyout task (kmsg-dest k))
  (when (kmsg-reply k) (copyout task (kmsg-reply k)))
  (mapc (lambda (d) (copyout-descriptor task d)) (kmsg-rights k)))

(defun mach-msg-send (message &key timeout)
  (with-ipc
    (let ((task *task*)
          (deadline (deadline timeout)))
      (loop
        (let* ((dest (kmsg-dest (copyin-message task message t)))
               (port (car dest)))
          (when (or (eq (cdr dest) :send-once)
                    (< (length (messages port)) (qlimit port)))
            (enqueue port (copyin-message task message nil))
            (return :mach-msg-success))
          (unless (wait (drained port) deadline)
            (pseudo-receive task (copyin-message task message nil))
            (fail :mach-send-timed-out)))))))

(defun deliver (task port)
  (let ((k (pop (messages port))))
    (broadcast (drained port))
    (send-possible port)
    (consume (kmsg-dest k))
    (let ((reply (kmsg-reply k)))
      (make-message
       :local-port (gethash port (names task))
       :local-disposition (moved (cdr (kmsg-dest k)))
       :remote-port (and reply (copyout task reply))
       :remote-disposition (and reply (moved (cdr reply)))
       :id (kmsg-id k)
       :body (kmsg-body k)
       :seqno (prog1 (seqno port) (incf (seqno port)))
       :descriptors (loop :for d :in (kmsg-rights k) :collect (copyout-descriptor task d))))))

(defun mach-msg-receive (name &key timeout)
  (with-ipc
    (let ((task *task*)
          (deadline (deadline timeout))
          (waited nil))
      (loop
        (let* ((e (gethash name (entries task)))
               (rights (and e (rights (check e))))
               (object (and e (object e))))
          (cond ((member :port-set rights)
                 (let ((port (find-if #'messages (members object))))
                   (when port (return (deliver task port)))))
                ((member :receive rights)
                 (when (messages object)
                   (return (deliver task object))))
                ((or waited (member :dead-name rights))
                 (fail :mach-rcv-port-died))
                (t (fail :mach-rcv-invalid-name)))
          (unless (wait (arrived object) deadline)
            (fail :mach-rcv-timed-out))
          (setf waited t))))))
