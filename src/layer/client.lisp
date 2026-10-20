(defpackage #:darterfly/layer
  (:use #:cl)
  (:export #:layer #:make-layer #:layer-id #:layer-position #:layer-bounds #:layer-frame
           #:layer-background-color #:layer-opacity #:layer-masks-to-bounds #:layer-sublayers
           #:context #:context-destroy #:context-create #:context-id #:context-layer #:commit
           #:layer-contents #:image #:next-event #:context-events #:window-create #:transaction-commit #:main-display-bounds #:activate-application))
(in-package #:darterfly/layer)

(defvar *next-layer-id* 0)

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
  (list :width width :height height :pixels pixels))

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
  (list :position (layer-position layer)
        :bounds (layer-bounds layer)
        :background-color (layer-background-color layer)
        :opacity (float (layer-opacity layer) 1.0)
        :masks-to-bounds (layer-masks-to-bounds layer)
        :contents (layer-contents layer)
        :sublayers (map 'vector #'layer-id (layer-sublayers layer))))

(defclass context ()
  ((id :initarg :id :reader context-id)
   (port :initarg :port :reader context-port)
   (events :initarg :events :reader context-events)
   (layer :initform nil :accessor context-layer)))

(defun render-server (&key (tries 100))
  (darterfly/init:bootstrap-look-up "windowserver")
  (loop :repeat tries
        :do (let ((port (darterfly/init:bootstrap-look-up "renderserver")))
              (when port (return port))
              (sleep 0.05))
        :finally (error "renderserver is not there")))

(defun context-create ()
  (if (darterfly/run:in-world-p)
      (remote-context-create)
      (local-context-create)))

(defun local-context-create ()
  (let ((server (render-server))
        (reply (darterfly/mach:mach-reply-port))
        (events (darterfly/mach:mach-port-allocate darterfly/mach:*task* :receive)))
    (darterfly/mach:mach-port-set-attributes darterfly/mach:*task* events :limits-info 1024)
    (darterfly/mach:mach-msg-send (darterfly/mach:make-message :remote-port server :local-port reply
                                                       :body (list :register-client :pid (darterfly/bsd:getpid))
                                                       :descriptors (list (cons events :make-send))))
    (let ((message (darterfly/mach:mach-msg-receive reply :timeout 5000)))
      (darterfly/mach:mach-port-mod-refs darterfly/mach:*task* reply :receive -1)
      (make-instance 'context :id (getf (darterfly/mach:msgh-body message) :context-id)
                              :port (car (first (darterfly/mach:msgh-descriptors message)))
                              :events events))))

(defun next-event (context &key timeout)
  (handler-case (darterfly/mach:msgh-body (darterfly/mach:mach-msg-receive (context-events context) :timeout timeout))
    (darterfly/mach:kern-return () nil)))

(defun tree (layer)
  (cons layer (mapcan #'tree (copy-list (layer-sublayers layer)))))

(defun tree-objects (root)
  (loop :for layer :in (tree root)
        :collect (cons (layer-id layer) (layer-object layer))))

(defun send-commit (port root layers)
  (darterfly/mach:mach-msg-send
   (darterfly/mach:make-message :remote-port port
                                :body (list :commit :root root :layers layers))))

(defun commit (context)
  (let ((root (context-layer context)))
    (if (darterfly/run:in-world-p)
        (remote-commit context (layer-id root) (tree-objects root))
        (send-commit (context-port context) (layer-id root) (tree-objects root)))))

(defclass connection ()
  ((window-server :initform nil :accessor connection-window-server)
   (lock :initform (sb-thread:make-mutex :name "connection") :reader connection-lock)))

(darterfly/bsd:define-process-variable *connection* (make-instance 'connection))

(defun window-server ()
  (sb-thread:with-mutex ((connection-lock *connection*))
    (or (connection-window-server *connection*)
        (setf (connection-window-server *connection*)
              (darterfly/init:bootstrap-look-up "windowserver")))))

(defun request (body &key reply)
  (if (darterfly/run:in-world-p)
      (remote-request body)
      (local-request body :reply reply)))

(defun local-request (body &key reply)
  (let ((port (and reply (darterfly/mach:mach-reply-port))))
    (darterfly/mach:mach-msg-send (darterfly/mach:make-message :remote-port (window-server) :local-port port :body body))
    (when port
      (prog1 (darterfly/mach:msgh-body (darterfly/mach:mach-msg-receive port :timeout 5000))
        (darterfly/mach:mach-port-mod-refs darterfly/mach:*task* port :receive -1)))))

(defun transaction-commit (forms)
  (request (list :transaction forms)))

(defun main-display-bounds ()
  (getf (request (list :display-bounds) :reply t) :bounds))

(defparameter +window-levels+
  '((:desktop . -2147483623) (:normal . 0) (:dock . 20) (:menu-background . 23) (:main-menu . 24) (:status . 25) (:pop-up-menu . 101)))

(defun window-create (context x y width height &key (level :normal) (order :above) (min-width 280) (min-height 180))
  (if (darterfly/run:in-world-p)
      (getf (remote-request (list :create-window :context (context-id context) :x x :y y :width width :height height
                                                 :level level :order order :min-width min-width :min-height min-height))
            :window)
      (local-window-create context x y width height level order min-width min-height)))

(defun local-window-create (context x y width height level order &optional (min-width 280) (min-height 180))
  (let ((window (getf (request (list :create-window :width width :height height :min-width min-width :min-height min-height) :reply t) :window)))
    (request (list :set-window-context window (context-id context)))
    (transaction-commit (list (list :shape window width height)
                              (list :level window (cdr (assoc level +window-levels+)))
                              (list :move window x y)
                              (list :order window order)))
    window))

(defun activate-application (name)
  (getf (request (list :activate-application name) :reply t) :activated))

(defun context-destroy (context)
  ;; Releasing the last client send right notifies WindowServer to retire its layers/windows.
  (darterfly/mach:mach-port-deallocate darterfly/mach:*task* (context-port context))
  (darterfly/mach:mach-port-mod-refs darterfly/mach:*task* (context-events context) :receive -1))

(export '(window-list window-restore window-metadata window-thumbnail dock-layout))
(defun window-list (&key (offset 0) (limit 128))
  (request (list :window-list :offset offset :limit limit) :reply t))
(defun window-restore (handle &key reduced-motion)
  (getf (request (list :restore-window handle :reduced-motion reduced-motion) :reply t) :restored))
(defun window-metadata (id title location &key private transient question)
  (request (list :window-metadata id :title title :location location :private private :transient transient :question question)))
(defun window-thumbnail (handle)
  (getf (request (list :window-thumbnail handle) :reply t) :thumbnail))

(defvar *dock-pinned-applications* '("Files" "Terminal" "Listener" "Generations"))
(export '*dock-pinned-applications*)

(defun dock-layout (windows width height)
  "Shared logical geometry for shell targets and compositor travel. No pixel data."
  (let* ((pinned *dock-pinned-applications*)
         (apps (append pinned (remove-duplicates
                               (loop for w in windows for app = (getf w :app)
                                     unless (member app pinned :test #'equal) collect app) :test #'equal)))
         (max-apps (max 4 (min 7 (floor (- (* width .78) 100) 68))))
         (shown (subseq apps 0 (min max-apps (length apps))))
         (hidden (sort (remove-if-not (lambda (w) (getf w :minimized)) (copy-list windows))
                       #'< :key (lambda (w) (getf w :minimized-at 0))))
         (slots (max 0 (min 3 (floor (- (* width .78) (+ 48 (* (length shown) 68) 76)) 90))))
         (items nil) (x 24))
    (dolist (app shown)
      (push (list :kind :app :key app :label app :frame (list x 8 44 44)
                  :count (count-if (lambda (w) (and (equal app (getf w :app)) (getf w :minimized))) windows)
                  :running (some (lambda (w) (equal app (getf w :app))) windows)) items)
      (incf x 68))
    (when hidden
      (incf x 12)
      (dolist (w (subseq hidden 0 (min slots (length hidden))))
        (push (list :kind :window :key (getf w :handle) :label (getf w :title)
                    :app (getf w :app) :version (list (getf w :minimized-at) (getf w :content-revision)) :frame (list x 8 72 44)) items)
        (incf x 90)))
    (when (or (> (length hidden) slots) (> (length apps) (length shown)))
      (push (list :kind :more :key :windows :label "Windows" :minimized-only (<= (length apps) (length shown)) :count (max 0 (- (length hidden) slots)) :frame (list x 8 56 44)) items)
      (incf x 72))
    (let ((w (+ x 0)))
      (list :frame (list (floor (- width w) 2) (- height 94) w 78) :items (nreverse items)))))
