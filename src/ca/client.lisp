(in-package #:finch/ca)

(defconstant +register-client+ 40202)
(defconstant +commit+ 40002)
(defconstant +masks-to-bounds+ 40)
(defparameter +flags-a+ 4612020269963255569)
(defparameter +flags-b+ 19331571768)

(defvar *next-layer-id* #x2c4f000000000000)

(defclass layer ()
  ((id :initform (incf *next-layer-id*) :reader layer-id)
   (position :initarg :position :initform #(0d0 0d0) :accessor layer-position)
   (bounds :initarg :bounds :initform #(0d0 0d0 0d0 0d0) :accessor layer-bounds)
   (background-color :initarg :background-color :initform #(0.0 0.0 0.0 0.0) :accessor layer-background-color)
   (opacity :initarg :opacity :initform 1.0 :accessor layer-opacity)
   (masks-to-bounds :initarg :masks-to-bounds :initform nil :accessor layer-masks-to-bounds)
   (sublayers :initarg :sublayers :initform nil :accessor layer-sublayers)
   (contents :initarg :contents :initform nil :accessor layer-contents)))

(defun image (width height pixels)
  (list :type +image+ :flags #x800400 :format 11 :width width :height height
        :rowbytes (list (* width 4)) :pixels pixels
        :colorspace (list 3) :texture-a #x3f800000 :texture-b (list 0 0 0 0) :shape 0
        :texture-c #x3f800000 :texture-d 0 :texture-e nil))

(defun make-layer (&rest initargs)
  (apply #'make-instance 'layer initargs))

(defun layer-frame (layer)
  (let ((p (layer-position layer)) (b (layer-bounds layer)))
    (vector (- (aref p 0) (/ (aref b 2) 2)) (- (aref p 1) (/ (aref b 3) 2)) (aref b 2) (aref b 3))))

(defun (setf layer-frame) (frame layer)
  (destructuring-bind (x y w h) (coerce frame 'list)
    (setf (layer-bounds layer) (vector 0d0 0d0 (float w 0d0) (float h 0d0))
          (layer-position layer) (vector (float (+ x (/ w 2)) 0d0) (float (+ y (/ h 2)) 0d0)))
    frame))

(defun layer-object (layer)
  (list :type +layer+ :flags 2
        :background-color (map 'vector (lambda (c) (float c 0.0)) (layer-background-color layer))
        :at-10 0 :opacity (round (* 255 (layer-opacity layer))) :shadow-opacity 0
        :contents-scale 1 :rasterization-scale 1
        :flags-a (if (layer-masks-to-bounds layer)
                     (logior +flags-a+ (ash 1 +masks-to-bounds+))
                     (logandc2 +flags-a+ (ash 1 +masks-to-bounds+)))
        :flags-b +flags-b+
        :position (map 'vector (lambda (v) (float v 0d0)) (layer-position layer))
        :bounds (map 'vector (lambda (v) (float v 0d0)) (layer-bounds layer))
        :contents (layer-contents layer)
        :sublayers (and (layer-sublayers layer) (map 'vector #'layer-id (layer-sublayers layer)))
        :mask 0 :name nil))

(defclass context ()
  ((id :initarg :id :reader context-id)
   (port :initarg :port :reader context-port)
   (events :initarg :events :reader context-events)
   (layer :initform nil :accessor context-layer)
   (commits :initform 0 :accessor commits)))

(defun now ()
  (/ (get-internal-real-time) (float internal-time-units-per-second 1d0)))

(defun render-server (&key (tries 100))
  (finch/launchd:bootstrap-look-up "windowserver")
  (loop :repeat tries
        :do (let ((port (finch/launchd:bootstrap-look-up "renderserver")))
              (when port (return port))
              (sleep 0.05))
        :finally (error "renderserver is not there")))

(defun context-create ()
  (let ((server (render-server))
        (reply (finch/mach:mach-reply-port))
        (events (finch/mach:mach-port-allocate finch/mach:*task* :receive)))
    (finch/mach:mach-port-set-attributes finch/mach:*task* events :limits-info 1024)
    (finch/mach:mach-msg-send (finch/mach:make-message :remote-port server :local-port reply
                                                       :id +register-client+
                                                       :body (list :pid (finch/bsd:getpid))
                                                       :descriptors (list (cons events :make-send))))
    (let ((message (finch/mach:mach-msg-receive reply :timeout 5000)))
      (finch/mach:mach-port-mod-refs finch/mach:*task* reply :receive -1)
      (make-instance 'context :id (getf (finch/mach:msgh-body message) :context-id)
                              :port (car (first (finch/mach:msgh-descriptors message)))
                              :events events))))

(defun next-event (context &key timeout)
  (handler-case (finch/server:decode-event
                 (finch/mach:msgh-body (finch/mach:mach-msg-receive (context-events context) :timeout timeout)))
    (finch/mach:kern-return () nil)))

(defun tree (layer)
  (cons layer (mapcan #'tree (copy-list (layer-sublayers layer)))))

(defun commit (context)
  (let* ((root (context-layer context))
         (time (now))
         (commands (append
                    (and (zerop (commits context))
                         (list (list :set-colorspace (list 1 36)) (list :set-layer-id (layer-id root))))
                    (loop :for layer :in (tree root)
                          :collect (list :set-object (layer-id layer) (if (eq layer root) 1 2)
                                         (layer-object layer) 0))
                    (list (list 32 (incf (commits context)) 0) (list 29 time)))))
    (finch/mach:mach-msg-send
     (finch/mach:make-message :remote-port (context-port context) :id +commit+
                              :body (encode-commit (list :flags 1 :context (context-id context)
                                                         :time time :commands commands))))))

(defconstant +create-window+ 30263)
(defconstant +main-display-bounds+ 33028)
(defconstant +set-window-layer-context+ 30264)
(defconstant +transaction-commit-async+ 30429)

(defclass connection ()
  ((window-server :initform nil :accessor connection-window-server)
   (transaction :initform 0 :accessor connection-transaction)
   (lock :initform (sb-thread:make-mutex :name "connection") :reader connection-lock)))

(finch/bsd:define-process-variable *connection* (make-instance 'connection))

(defun window-server ()
  (sb-thread:with-mutex ((connection-lock *connection*))
    (or (connection-window-server *connection*)
        (setf (connection-window-server *connection*)
              (finch/launchd:bootstrap-look-up "windowserver")))))

(defun octets (&rest words)
  (let ((w (make-array 0 :element-type '(unsigned-byte 8) :adjustable t :fill-pointer 0)))
    (dolist (word words)
      (destructuring-bind (size . value) (if (consp word) word (cons 4 word))
        (dotimes (i size) (vector-push-extend (ldb (byte 8 (* 8 i)) value) w))))
    w))

(defun mig (id body &key descriptors reply)
  (let ((port (and reply (finch/mach:mach-reply-port))))
    (finch/mach:mach-msg-send (finch/mach:make-message :remote-port (window-server) :local-port port
                                                       :id id :body (coerce body '(simple-array (unsigned-byte 8) (*)))
                                                       :descriptors descriptors))
    (when port
      (prog1 (finch/mach:mach-msg-receive port :timeout 5000)
        (finch/mach:mach-port-mod-refs finch/mach:*task* port :receive -1)))))

(defun transaction-commit (forms)
  (let* ((stream (finch/server:encode-transaction forms))
         (body (octets 0 1 (incf (connection-transaction *connection*)) '(8 . 0) (length stream))))
    (loop :for b :across stream :do (vector-push-extend b body))
    (loop :until (zerop (mod (length body) 4)) :do (vector-push-extend 0 body))
    (loop :for b :across (octets 0) :do (vector-push-extend b body))
    (mig +transaction-commit-async+ body
         :descriptors (list (make-array 0 :element-type '(unsigned-byte 8))))))

(defun main-display-bounds ()
  (let ((body (finch/mach:msgh-body (mig +main-display-bounds+ (octets 0 1) :reply t))))
    (flet ((i32 (at) (logior (aref body at) (ash (aref body (+ at 1)) 8) (ash (aref body (+ at 2)) 16) (ash (aref body (+ at 3)) 24))))
      (list (i32 8) (i32 12) (i32 16) (i32 20)))))

(defparameter +window-levels+
  '((:desktop . -2147483623) (:normal . 0) (:dock . 20) (:main-menu . 24) (:status . 25) (:pop-up-menu . 101)))

(defun window-create (context x y width height &key (level :normal) (order :above))
  (let* ((reply (mig +create-window+ (octets 0 1 5 12 #x10000 0 1 0)
                     :descriptors (list (finch/server:rect-region 0 0 0 0)) :reply t))
         (body (finch/mach:msgh-body reply))
         (window (logior (aref body 8) (ash (aref body 9) 8) (ash (aref body 10) 16) (ash (aref body 11) 24))))
    (mig +set-window-layer-context+ (octets 0 1 window (context-id context)))
    (transaction-commit (list (list "SetWindowShape" window (finch/server:rect-region 0 0 width height))
                              (list "SetWindowLevel" window (cdr (assoc level +window-levels+)))
                              (list "MoveWindowWithGroup" window (float x 1d0) (float y 1d0))
                              (list "OrderWindow" window (ecase order (:above 1) (:below -1)) 0)))
    window))
