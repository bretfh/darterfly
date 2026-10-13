(defpackage #:finch/mach
  (:use #:cl)
  (:export
   #:task #:make-task #:task-name #:*task* #:mach-task-self
   #:kern-return #:kern-return-name #:kern-return-code
   #:mach-port-allocate #:mach-port-insert-right #:mach-port-deallocate
   #:mach-port-mod-refs #:mach-port-destroy #:mach-port-type
   #:mach-port-get-refs #:mach-port-move-member #:mach-port-names
   #:mach-port-request-notification #:mach-port-allocate-name
   #:mach-port-get-attributes #:mach-port-set-attributes #:mach-port-set-mscount
   #:mach-port-set-seqno #:mach-port-set-context #:mach-port-get-context
   #:mach-port-get-set-status #:mach-port-extract-right #:msgh-seqno
   #:message #:make-message #:msgh-remote-port #:msgh-local-port
   #:msgh-remote-disposition #:msgh-local-disposition #:msgh-id
   #:msgh-body #:msgh-descriptors
   #:mach-msg-send #:mach-msg-receive
   #:+mach-port-qlimit-default+))
(in-package #:finch/mach)

(defparameter +kern-return+
  '((:kern-success . 0)
    (:kern-invalid-argument . 4)
    (:kern-name-exists . 13)
    (:kern-invalid-name . 15)
    (:kern-invalid-right . 17)
    (:kern-invalid-value . 18)
    (:kern-urefs-overflow . 19)
    (:kern-invalid-capability . 20)
    (:kern-right-exists . 21)
    (:mach-send-invalid-dest . #x10000003)
    (:mach-send-timed-out . #x10000004)
    (:mach-send-invalid-reply . #x10000009)
    (:mach-send-invalid-right . #x1000000a)
    (:mach-send-invalid-header . #x10000010)
    (:mach-rcv-invalid-name . #x10004002)
    (:mach-rcv-timed-out . #x10004003)
    (:mach-rcv-port-changed . #x10004006)
    (:mach-rcv-port-died . #x10004009)
    (:mach-rcv-in-set . #x1000400a)))

(define-condition kern-return (error)
  ((name :initarg :name :reader kern-return-name))
  (:report (lambda (c s)
             (format s "~a (#x~8,'0x)"
                     (substitute #\_ #\- (symbol-name (kern-return-name c)))
                     (kern-return-code c)))))

(defun kern-return-code (c)
  (cdr (assoc (if (typep c 'kern-return) (kern-return-name c) c) +kern-return+)))

(defun fail (name)
  (error 'kern-return :name name))
