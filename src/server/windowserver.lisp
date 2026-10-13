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
))

(defconstant +create-window+ 30263)
(defconstant +set-window-layer-context+ 30264)
(defconstant +transaction-commit-async+ 30429)

(defclass window ()
  ((id :initarg :id :reader window-id)
   (owner :initarg :owner :reader owner)
   (port :initarg :port :reader window-port)
   (context :initform nil :accessor window-context)
   (x :initform 0 :accessor window-x)
   (y :initform 0 :accessor window-y)
   (width :initform 0 :accessor window-width)
   (height :initform 0 :accessor window-height)
   (ordered :initform nil :accessor ordered)
   (level :initform 0 :accessor window-level)))

(defun by-level (windows)
  (stable-sort (copy-list windows) #'> :key #'window-level))

(defvar *windows* nil)
(defvar *next-window* #x20)
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

(defun window-frame (window)
  (list (window-x window) (window-y window)
        (+ (window-x window) (window-width window)) (+ (window-y window) (window-height window))))

(defun window-at (x y)
  (find-if (lambda (window)
             (and (visible-p window)
                  (destructuring-bind (x0 y0 x1 y1) (window-frame window)
                    (and (<= x0 x x1) (<= y0 y y1)))))
           (by-level *windows*)))

(defun context-client (context)
  (find context *clients* :key #'context))

(defconstant +main-menu-level+ 24)

(defun key-window ()
  (find-if (lambda (w) (and (ordered w) (<= (window-level w) 0))) *windows*))

(defun key-client ()
  (let ((window (key-window)))
    (and window (find (owner window) *clients* :key #'pid))))

(defun visible-p (window)
  (and (ordered window)
       (or (/= (window-level window) +main-menu-level+)
           (let ((key (key-window)))
             (or (and key (eql (owner key) (owner window)))
                 (notany (lambda (w) (and (eql (owner w) (owner window)) (<= (window-level w) 0)))
                         *windows*))))))

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
    (dolist (window (reverse (by-level *windows*)))
      (let ((client (and (visible-p window) (context-client (window-context window)))))
        (when (and client (root client))
          (draw-layer fb (layers client) (root client) (window-x window) (window-y window)
                      (intersect screen (window-frame window)) 1.0))))
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
          (let ((window (first *drag*)))
            (incf (window-x window) (- nx x))
            (incf (window-y window) (- ny y))))
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
                 (let ((window (window-at x y)))
                   (when window
                     (setf *windows* (cons window (remove window *windows*)))
                     (if (and (zerop (window-level window)) (< y (+ (window-y window) +title-height+))
                              (> (- x (window-x window)) 76))
                         (setf *drag* (list window))
                         (click window :left-mouse-down x y)))))
               (destructuring-bind (x y) *cursor*
                 (let ((window (window-at x y)))
                   (when (and window (not *drag*))
                     (click window :left-mouse-up x y)))
                 (setf *drag* nil)))))))

(defun click (window type x y)
  (let ((client (find (owner window) *clients* :key #'pid)))
    (post-event client (server:encode-event
                        (server:mouse-event type x y :timestamp (get-internal-real-time)
                                                     :window (window-id window)
                                                     :wx (- x (window-x window)) :wy (- y (window-y window)))))))

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
                 (post-event (key-client)
                             (server:encode-event
                              (server:key-event t (or (io:virtual-keycode code) 0) char
                                                :timestamp (get-internal-real-time)
                                                :location (mapcar (lambda (v) (float v 1.0)) *cursor*)))))))))))

(defun hid-devices ()
  (loop :for name :in (ignore-errors (bsd:readdir "/dev/input"))
        :when (uiop:string-prefix-p "event" name)
          :collect (io:open-hid (format nil "/dev/input/~a" name))))

(defun drain (devices)
  (loop :for batch := (loop :for fd :in devices :append (io:read-events fd))
        :while batch
        :append batch))

(defun hid-loop ()
  (let ((devices (hid-devices)))
    (loop
      (let ((events (drain devices)))
        (if events
            (sb-thread:with-mutex (*lock*)
              (let ((before (list *cursor* (first *windows*) (and *drag* (window-x (first *drag*))) (and *drag* (window-y (first *drag*))))))
                (mapc #'keyboard events)
                (mapc #'pointer events)
                (unless (equal before (list *cursor* (first *windows*) (and *drag* (window-x (first *drag*))) (and *drag* (window-y (first *drag*)))))
                  (render))))
            (sleep 0.005))))))

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

(defun le32 (octets at)
  (logior (aref octets at) (ash (aref octets (+ at 1)) 8)
          (ash (aref octets (+ at 2)) 16) (ash (aref octets (+ at 3)) 24)))

(defun put32 (w v) (dotimes (i 4) (vector-push-extend (ldb (byte 8 (* 8 i)) v) w)))

(defun mig-body (&rest words)
  (let ((w (make-array 0 :element-type '(unsigned-byte 8) :adjustable t :fill-pointer 0)))
    (put32 w 0) (put32 w 1)
    (dolist (v words) (put32 w v))
    (coerce w '(simple-array (unsigned-byte 8) (*)))))

(defun find-window (id) (find id *windows* :key #'window-id))

(defun create-window (message)
  (let* ((port (mach:mach-port-allocate mach:*task* :receive))
         (window (make-instance 'window :id (incf *next-window*) :port port
                                        :owner (bsd:task-pid (mach:msgh-audit message))))
         (region (first (mach:msgh-descriptors message))))
    (when (vectorp region)
      (destructuring-bind (x y w h) (server:region-bounds region)
        (declare (ignore x y))
        (setf (window-width window) w (window-height window) h)))
    (setf *windows* (append *windows* (list window)))
    (mach:mach-msg-send (mach:make-message :remote-port (mach:msgh-remote-port message)
                                           :remote-disposition :move-send-once :id (+ +create-window+ 100)
                                           :body (mig-body (window-id window))
                                           :descriptors (list (cons port :make-send))))))

(defun set-window-layer-context (message)
  (let* ((body (mach:msgh-body message))
         (window (find-window (le32 body 8))))
    (when window
      (setf (window-context window) (le32 body 12)))))

(defun apply-transaction (forms)
  (dolist (form forms)
    (destructuring-bind (name &rest args) form
      (let ((window (find-window (first args))))
        (when window
          (cond ((string= name "SetWindowShape")
                 (destructuring-bind (x y w h) (server:region-bounds (second args))
                   (declare (ignore x y))
                   (setf (window-width window) w (window-height window) h)))
                ((string= name "MoveWindowWithGroup")
                 (setf (window-x window) (round (second args)) (window-y window) (round (third args))))
                ((string= name "SetWindowLevel")
                 (setf (window-level window) (second args)))
                ((string= name "OrderWindow")
                 (let ((order (second args)))
                   (setf (ordered window) (/= order 0))
                   (when (= order 1) (setf *windows* (cons window (remove window *windows*))))))))))))

(defun transaction-commit (message)
  (let* ((body (mach:msgh-body message))
         (length (le32 body 20))
         (stream (subseq body 24 (+ 24 length))))
    (apply-transaction (server:decode-transaction stream))))

(defun client-of (port)
  (find port *clients* :key #'port))

(defun serve (render-server set)
  (loop
    (let* ((message (mach:mach-msg-receive set))
           (port (mach:msgh-local-port message)))
      (cond ((eql port render-server)
             (when (= (mach:msgh-id message) +register-client+)
               (register-client message set)))
            ((= (mach:msgh-id message) +create-window+)
             (sb-thread:with-mutex (*lock*) (create-window message)))
            ((= (mach:msgh-id message) +set-window-layer-context+)
             (sb-thread:with-mutex (*lock*) (set-window-layer-context message) (render)))
            ((= (mach:msgh-id message) +transaction-commit-async+)
             (sb-thread:with-mutex (*lock*) (transaction-commit message) (render)))
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
        *windows* nil
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
    (finch/launchd:bootstrap-look-up "com.apple.loginwindow")
    (format t "WindowServer: ~dx~d, CARenderServer #x~x~%"
            (io:framebuffer-width *framebuffer*) (io:framebuffer-height *framebuffer*) render-server)
    (finish-output)
    (serve render-server set)))
