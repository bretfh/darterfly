(defpackage #:darterfly/drivers
  (:use #:cl)
  (:local-nicknames (#:devices #:darterfly/devices) (#:worlds #:darterfly/worlds) (#:run #:darterfly/run))
  (:export #:grant-device #:attach-controller #:start-driver-world #:serve-requests
           #:serve-network #:remote-network #:start-network-world))
(in-package #:darterfly/drivers)

(defun pci-address (node)
  (list :ecam (devices::bridge-ecam (devices::device-bridge node))
        :bus (devices::pci-bus node)
        :device (devices::pci-device node)
        :function (devices::pci-function node)))

(defun grant-bars (world node)
  (let ((index 0))
    (loop :while (< index 6)
          :do (let ((address (devices::bar-address node index))
                    (wide (devices::bar-64-p node index)))
                (when (and address (plusp address))
                  (worlds:grant-memory world address (devices::bar-length node index)))
                (incf index (if wide 2 1))))))

(defun grant-device (world node)
  (destructuring-bind (&key ecam bus device function) (pci-address node)
    (let ((vector (or (devices:allocate-vector) (error "no interrupt vector left"))))
      (worlds:grant-memory world (+ ecam (ash bus 20)) (ash 1 20) :reserve)
      (worlds:grant-memory world (+ ecam (ash bus 20) (ash device 15) (ash function 12)) 4096)
      (grant-bars world node)
      (worlds:grant-vectors world vector)
      (list :ecam ecam :bus bus :device device :function function :vector vector))))

(defun attach-controller (ecam bus device function vector)
  (setf devices::*free-vectors* (list vector)
        devices:*registry-root* (make-instance 'devices:entry :name "Root"))
  (let* ((bridge (make-instance 'devices::acpi-pci :ecam ecam))
         (node (make-instance 'devices:pci-node :bridge bridge :bus bus :device device :function function)))
    (devices::attach node devices:*registry-root*)
    (devices::describe-pci-device node)
    (devices:register-service node)))

(defun eval-in (world form)
  (let ((*package* (find-package :darterfly/drivers)))
    (read-from-string
     (run:world-eval world (with-standard-io-syntax
                             (let ((*package* (find-package :cl-user)))
                               (prin1-to-string form)))))))

(defun start-driver-world (node core &key name serve)
  (let* ((world (run:start-world core (run::world-argv "(loop (sleep 60))") :cwd "/" :disk t :attach t :name name))
         (id (run:world-id world)))
    (loop :repeat 300 :until (ignore-errors (run:world-eval world "t")) :do (sleep 0.1))
    (let ((granted (grant-device id node)))
      (multiple-value-bind (theirs ours) (worlds:port-into id)
        (let ((started (eval-in world (list* serve theirs granted))))
          (values world ours started))))))

(defun serve-requests (port handle &key (name "requests"))
  (sb-thread:make-thread
   (lambda ()
     (let ((buffer (make-array 65536 :element-type '(unsigned-byte 8))))
       (loop
         (multiple-value-bind (n token)
             (handler-case (worlds:receive-into port buffer)
               (worlds:world-error () (values nil nil)))
           (when n
             (let ((request (subseq buffer 0 n)))
               (sb-thread:make-thread
                (lambda () (worlds:reply token (funcall handle request token)))
                :name name)))))))
   :name name))

(defun u64 (v at) (loop :for i :below 8 :sum (ash (aref v (+ at i)) (* 8 i))))

(defun octets (&rest numbers)
  (let ((out (make-array (* 8 (length numbers)) :element-type '(unsigned-byte 8))))
    (loop :for n :in numbers :for at :from 0 :by 8
          :do (dotimes (i 8) (setf (aref out (+ at i)) (ldb (byte 8 (* 8 i)) n))))
    out))

(defconstant +send+ 1)
(defconstant +receive+ 2)
(defconstant +receive-wait+ 0.1)

(defvar *nic* nil)
(defvar *pending* nil)
(defvar *receive-lock* (sb-thread:make-mutex :name "network receive"))

(defun next-frames ()
  (let ((deadline (+ (get-internal-real-time) (round (* +receive-wait+ internal-time-units-per-second))))
        (vector (devices:interrupt-vector *nic*)))
    (loop
      (let ((frames (or (shiftf *pending* nil) (devices:network-receive *nic*))))
        (when (or frames (> (get-internal-real-time) deadline))
          (return frames))
        (if vector
            (devices:wait-for-interrupt (list vector) +receive-wait+)
            (sleep 0.002))))))

(defun pack-frames (frames room)
  (let ((out (make-array room :element-type '(unsigned-byte 8)))
        (at 0))
    (loop :for (frame . more) :on frames
          :do (when (> (+ at 2 (length frame)) room)
                (setf *pending* (cons frame more))
                (return))
              (setf (aref out at) (ldb (byte 8 0) (length frame))
                    (aref out (1+ at)) (ldb (byte 8 8) (length frame)))
              (replace out frame :start1 (+ at 2))
              (incf at (+ 2 (length frame))))
    (values out at)))

(defun handle-network (request token)
  (let ((op (u64 request 0))
        (address (u64 request 8))
        (size (u64 request 16)))
    (cond ((= op +send+)
           (let ((frame (make-array size :element-type '(unsigned-byte 8))))
             (sb-sys:with-pinned-objects (frame)
               (worlds:copy-from token address (sb-sys:sap-int (sb-sys:vector-sap frame)) size))
             (devices:network-send *nic* frame)
             (octets size)))
          ((= op +receive+)
           (sb-thread:with-mutex (*receive-lock*)
             (multiple-value-bind (packed length) (pack-frames (next-frames) size)
               (when (plusp length)
                 (sb-sys:with-pinned-objects (packed)
                   (worlds:copy-into token address (sb-sys:sap-int (sb-sys:vector-sap packed)) length)))
               (octets length))))
          (t (octets 0)))))

(defun serve-network (port &key ecam bus device function vector)
  (attach-controller ecam bus device function vector)
  (setf *nic* (or (first (devices:find-entries 'devices:ethernet-controller))
                  (error "no network controller on the granted device")))
  (serve-requests port #'handle-network :name "network")
  (coerce (devices:network-mac *nic*) 'list))

(devices::define-device-class remote-network "RemoteNetwork" (devices:ethernet-controller)
  ((world :initarg :world :reader remote-world)
   (port :initarg :port :reader remote-port)
   (mac :initarg :mac :accessor devices:network-mac)
   (buffer :initform (make-array 65536 :element-type '(unsigned-byte 8)) :reader receive-buffer)
   (lock :initform (sb-thread:make-mutex :name "remote network") :reader remote-lock)))

(defmethod devices:network-send ((net remote-network) frame)
  (let ((frame (coerce frame '(simple-array (unsigned-byte 8) (*)))))
    (sb-sys:with-pinned-objects (frame)
      (worlds:call (remote-port net) (octets +send+ (sb-sys:sap-int (sb-sys:vector-sap frame)) (length frame))
                   :timeout 5))
    (length frame)))

(defmethod devices:network-receive ((net remote-network))
  (sb-thread:with-mutex ((remote-lock net))
    (let* ((buffer (receive-buffer net))
           (length (sb-sys:with-pinned-objects (buffer)
                     (u64 (worlds:call (remote-port net)
                                       (octets +receive+ (sb-sys:sap-int (sb-sys:vector-sap buffer)) (length buffer))
                                       :timeout 5)
                          0))))
      (loop :with at := 0
            :while (< at length)
            :collect (let ((size (logior (aref buffer at) (ash (aref buffer (1+ at)) 8))))
                       (prog1 (subseq buffer (+ at 2) (+ at 2 size))
                         (incf at (+ 2 size))))))))

(defmethod devices:interrupt-vector ((net remote-network)) nil)

(defun watch-driver-world (world net)
  (sb-thread:make-thread
   (lambda ()
     (sb-thread:join-thread (run::world-thread world) :default nil)
     (devices::detach net)
     (devices::announce :removed net))
   :name "network world"))

(defun start-network-world (node core &key (name "network"))
  (multiple-value-bind (world port mac) (start-driver-world node core :name name :serve 'serve-network)
    (let ((net (make-instance 'remote-network :name "RemoteNetwork" :world world :port port
                                              :mac (coerce mac '(vector (unsigned-byte 8))))))
      (devices::attach net node)
      (watch-driver-world world net)
      (devices::announce :added net)
      (values world net))))
