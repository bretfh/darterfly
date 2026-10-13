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
  (finch/launchd:bootstrap-look-up "com.apple.windowserver")
  (loop :repeat tries
        :do (let ((port (finch/launchd:bootstrap-look-up "com.apple.CARenderServer")))
              (when port (return port))
              (sleep 0.05))
        :finally (error "com.apple.CARenderServer is not there")))

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
  (handler-case (finch/mach:msgh-body (finch/mach:mach-msg-receive (context-events context) :timeout timeout))
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
