(defpackage #:finch/windowserver
  (:use #:cl)
  (:local-nicknames (#:bsd #:finch/bsd) (#:mach #:finch/mach) (#:ca #:finch/ca) (#:io #:finch/io) (#:server #:finch/server)
                    (#:launchd #:finch/launchd)))
(in-package #:finch/windowserver)

(defconstant +register-client+ 40202)
(defconstant +mach-notify-no-senders+ #o106)
(defparameter +desktop+ #(0.18 0.36 0.56))

(defclass client ()
  ((port :initarg :port :reader port)
   (context :initarg :context :reader context)
   (pid :initarg :pid :reader pid)
   (layers :initform (make-hash-table) :reader layers)
   (root :initform nil :accessor root)
   (events :initarg :events :initform nil :reader events)
   (dx :initform 0 :accessor dx)
   (dy :initform 0 :accessor dy)))

(defvar *clients* nil)
(defvar *next-context* #x1000)
(defvar *framebuffer* nil)
(defvar *lock* (sb-thread:make-mutex :name "WindowServer"))
(defvar *cursor* (list 512 384))
(defvar *drag* nil)
(defparameter +title-height+ 28)

(defparameter +arrow+
  #("X           "
    "XX          "
    "X.X         "
    "X..X        "
    "X...X       "
    "X....X      "
    "X.....X     "
    "X......X    "
    "X.......X   "
    "X........X  "
    "X.........X "
    "X......XXXXX"
    "X...X..X    "
    "X..XX..X    "
    "X.X  X..X   "
    "XX   X..X   "
    "X     X..X  "
    "      X..X  "
    "       XX   "))

(defun draw-cursor (fb)
  (destructuring-bind (cx cy) *cursor*
    (loop :for row :across +arrow+
          :for y :from cy
          :do (loop :for c :across row
                    :for x :from cx
                    :do (case c
                          (#\X (io:blend-rect fb x y (1+ x) (1+ y) 0.0 0.0 0.0 1.0))
                          (#\. (io:blend-rect fb x y (1+ x) (1+ y) 1.0 1.0 1.0 1.0)))))))

(defun window-frame (client)
  (let ((layer (gethash (root client) (layers client))))
    (when layer
      (destructuring-bind (px py) (coerce (getf layer :position) 'list)
        (destructuring-bind (bx by bw bh) (coerce (getf layer :bounds) 'list)
          (declare (ignore bx by))
          (let ((x (+ (dx client) (- px (/ bw 2)))) (y (+ (dy client) (- py (/ bh 2)))))
            (list x y (+ x bw) (+ y bh))))))))

(defun window-at (x y)
  (find-if (lambda (client)
             (let ((frame (and (root client) (window-frame client))))
               (and frame (<= (first frame) x (third frame)) (<= (second frame) y (fourth frame)))))
           *clients*))

(defun draw-layer (fb layers id ox oy clip alpha)
  (let ((layer (gethash id layers)))
    (when layer
      (destructuring-bind (px py) (coerce (getf layer :position) 'list)
        (destructuring-bind (bx by bw bh) (coerce (getf layer :bounds) 'list)
          (let* ((x (+ ox (- px (/ bw 2))))
                 (y (+ oy (- py (/ bh 2))))
                 (alpha (* alpha (/ (getf layer :opacity) 255.0)))
                 (frame (list (round x) (round y) (round (+ x bw)) (round (+ y bh))))
                 (inner (if (logbitp ca:+masks-to-bounds+ (getf layer :flags-a))
                            (intersect clip frame)
                            clip)))
            (destructuring-bind (r g b a) (coerce (getf layer :background-color) 'list)
              (destructuring-bind (x0 y0 x1 y1) (intersect clip frame)
                (io:blend-rect fb x0 y0 x1 y1 r g b (* a alpha))))
            (let ((image (contents layer)))
              (when (and image (getf image :pixels))
                (io:blit-image fb (round x) (round y) (round bw) (round bh)
                               (coerce (getf image :pixels) '(simple-array (unsigned-byte 8) (*)))
                               (getf image :width) (getf image :height) (float alpha 1.0) inner)))
            (loop :for child :across (or (getf layer :sublayers) #())
                  :do (draw-layer fb layers child (- x bx) (- y by) inner alpha))))))))

(defun contents (layer)
  (let ((c (getf layer :contents)))
    (if (eq (getf c :type) :cached) (getf c :object) c)))

(defun intersect (a b)
  (list (max (first a) (first b)) (max (second a) (second b))
        (min (third a) (third b)) (min (fourth a) (fourth b))))

(defun render ()
  (let* ((fb *framebuffer*)
         (screen (list 0 0 (io:framebuffer-width fb) (io:framebuffer-height fb))))
    (destructuring-bind (r g b) (coerce +desktop+ 'list)
      (io:blend-rect fb 0 0 (third screen) (fourth screen) r g b 1.0))
    (dolist (client (reverse *clients*))
      (when (root client)
        (draw-layer fb (layers client) (root client) (dx client) (dy client) screen 1.0)))
    (draw-cursor fb)
    (io:flush fb)))

(defconstant +ev-key+ 1)
(defconstant +ev-rel+ 2)
(defconstant +rel-x+ 0)
(defconstant +rel-y+ 1)
(defconstant +btn-left+ #x110)

(defconstant +ev-abs+ 3)
(defconstant +abs-max+ 32768)

(defun move-cursor (nx ny)
  (let ((fb *framebuffer*))
    (destructuring-bind (x y) *cursor*
      (let ((nx (max 0 (min (1- (io:framebuffer-width fb)) nx)))
            (ny (max 0 (min (1- (io:framebuffer-height fb)) ny))))
        (when *drag*
          (destructuring-bind (client . nil) *drag*
            (incf (dx client) (- nx x))
            (incf (dy client) (- ny y))))
        (setf *cursor* (list nx ny))))))

(defun pointer (event)
  (let ((fb *framebuffer*))
    (cond ((= (io:event-type event) +ev-rel+)
           (destructuring-bind (x y) *cursor*
             (move-cursor (+ x (if (= (io:event-code event) +rel-x+) (io:event-value event) 0))
                          (+ y (if (= (io:event-code event) +rel-y+) (io:event-value event) 0)))))
          ((and (= (io:event-type event) +ev-abs+) (<= 0 (io:event-code event) 1))
           (destructuring-bind (x y) *cursor*
             (let* ((range (or (io:abs-range (io:event-fd event) (io:event-code event)) (cons 0 +abs-max+)))
                    (span (max 1 (- (cdr range) (car range))))
                    (at (- (io:event-value event) (car range))))
               (case (io:event-code event)
                 (0 (move-cursor (floor (* at (io:framebuffer-width fb)) span) y))
                 (1 (move-cursor x (floor (* at (io:framebuffer-height fb)) span)))))))
          ((and (= (io:event-type event) +ev-key+) (= (io:event-code event) +btn-left+))
           (if (plusp (io:event-value event))
               (destructuring-bind (x y) *cursor*
                 (let ((client (window-at x y)))
                   (when client
                     (setf *clients* (cons client (remove client *clients*)))
                     (when (< y (+ (second (window-frame client)) +title-height+))
                       (setf *drag* (list client))))))
               (setf *drag* nil))))))

(defvar *shift* nil)

(defun post-event (client body)
  (when (and client (events client))
    (handler-case
        (mach:mach-msg-send (mach:make-message :remote-port (events client) :body body) :timeout 0)
      (mach:kern-return () nil))))

(defun keyboard (event)
  (when (= (io:event-type event) +ev-key+)
    (let ((code (io:event-code event))
          (value (io:event-value event)))
      (cond ((io:shift-key-p code) (setf *shift* (plusp value)))
            ((plusp value)
             (let ((char (io:key-character code *shift*)))
               (when char
                 (post-event (first *clients*)
                             (server:encode-event
                              (server:key-event t (or (io:virtual-keycode code) 0) char
                                                :timestamp (get-internal-real-time)
                                                :location (mapcar (lambda (v) (float v 1.0)) *cursor*)))))))))))

(defun hid-devices ()
  (loop :for name :in (ignore-errors (bsd:readdir "/dev/input"))
        :when (uiop:string-prefix-p "event" name)
          :collect (io:open-hid (format nil "/dev/input/~a" name))))

(defun hid-loop ()
  (let ((devices (hid-devices)))
    (loop
      (let ((events (loop :for fd :in devices :append (io:read-events fd))))
        (if events
            (sb-thread:with-mutex (*lock*)
              (mapc #'pointer events)
              (mapc #'keyboard events)
              (render))
            (sleep 0.01))))))

(defun apply-commit (client octets)
  (dolist (command (getf (ca:decode-commit octets) :commands))
    (case (first command)
      (:set-object (setf (gethash (second command) (layers client)) (fourth command)))
      (:delete-object (remhash (second command) (layers client)))
      (:set-layer-id (setf (root client) (second command))))))

(defun register-client (message set)
  (sb-thread:with-mutex (*lock*)
    (%register-client message set)))

(defun %register-client (message set)
  (let ((port (mach:mach-port-allocate mach:*task* :receive))
        (context (incf *next-context*)))
    (mach:mach-port-move-member mach:*task* port set)
    (mach:mach-port-request-notification mach:*task* port :no-senders 1 port :make-send-once)
    (push (make-instance 'client :port port :context context
                                 :pid (getf (mach:msgh-body message) :pid)
                                 :events (car (first (mach:msgh-descriptors message))))
          *clients*)
    (mach:mach-msg-send (mach:make-message :remote-port (mach:msgh-remote-port message)
                                           :remote-disposition :move-send-once
                                           :body (list :kr 0 :context-id context)
                                           :descriptors (list (cons port :make-send))))))

(defun client-of (port)
  (find port *clients* :key #'port))

(defun serve (render-server set)
  (loop
    (let* ((message (mach:mach-msg-receive set))
           (port (mach:msgh-local-port message)))
      (cond ((eql port render-server)
             (when (= (mach:msgh-id message) +register-client+)
               (register-client message set)))
            ((= (mach:msgh-id message) +mach-notify-no-senders+)
             (sb-thread:with-mutex (*lock*)
               (let ((client (client-of port)))
                 (when client
                   (setf *clients* (remove client *clients*))
                   (mach:mach-port-mod-refs mach:*task* port :receive -1)
                   (render)))))
            ((<= 40002 (mach:msgh-id message) 40005)
             (sb-thread:with-mutex (*lock*)
               (let ((client (client-of port)))
                 (when client
                   (apply-commit client (mach:msgh-body message))
                   (render)))))))))

(bsd:define-program "WindowServer" (argv envp)
  (setf *framebuffer* (io:open-framebuffer)
        *clients* nil
        *cursor* (list (floor (io:framebuffer-width *framebuffer*) 2)
                       (floor (io:framebuffer-height *framebuffer*) 2)))
  (render)
  (bsd:bsdthread-create #'hid-loop "hid")
  (let ((set (mach:mach-port-allocate mach:*task* :port-set))
        (render-server (launchd:bootstrap-check-in "com.apple.CARenderServer")))
    (dolist (name '("com.apple.windowserver" "com.apple.windowserver.active"))
      (let ((port (launchd:bootstrap-check-in name)))
        (when port (mach:mach-port-move-member mach:*task* port set))))
    (mach:mach-port-move-member mach:*task* render-server set)
    (format t "WindowServer: ~dx~d, CARenderServer #x~x~%"
            (io:framebuffer-width *framebuffer*) (io:framebuffer-height *framebuffer*) render-server)
    (finish-output)
    (serve render-server set)))
