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
   (ports :initarg :ports :initform nil :accessor msgh-ports)))

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
  (mapc #'release (kmsg-rights kmsg)))

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
   :rights (loop :for (name . disposition) :in (msgh-ports m)
                 :collect (copyin task name disposition
                                  :absent :mach-send-invalid-right
                                  :wrong :mach-send-invalid-right :dry dry))))

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
  (mapc (lambda (carried) (copyout task carried)) (kmsg-rights k)))

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
    (consume (kmsg-dest k))
    (let ((reply (kmsg-reply k)))
      (make-message
       :local-port (gethash port (names task))
       :local-disposition (moved (cdr (kmsg-dest k)))
       :remote-port (and reply (copyout task reply))
       :remote-disposition (and reply (moved (cdr reply)))
       :id (kmsg-id k)
       :body (kmsg-body k)
       :ports (loop :for carried :in (kmsg-rights k)
                    :collect (cons (copyout task carried) (moved (cdr carried))))))))

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
