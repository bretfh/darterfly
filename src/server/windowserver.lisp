(defpackage #:darterfly/windowserver
  (:use #:cl)
  (:local-nicknames (#:bsd #:darterfly/bsd) (#:mach #:darterfly/mach) (#:layer #:darterfly/layer) (#:io #:darterfly/io) (#:server #:darterfly/server)
                    (#:init #:darterfly/init)))
(in-package #:darterfly/windowserver)

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
  (find-if (lambda (w) (and (ordered w) (<= (window-level w) 0))) (by-level *windows*)))

(defun key-client ()
  (let ((window (key-window)))
    (and window (context-client (window-context window)))))

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
                 (alpha (* alpha (getf layer :opacity)))
                 (frame (list (round x) (round y) (round (+ x bw)) (round (+ y bh))))
                 (inner (if (getf layer :masks-to-bounds)
                            (intersect clip frame)
                            clip)))
            (destructuring-bind (r g b a) (coerce (getf layer :background-color) 'list)
              (destructuring-bind (x0 y0 x1 y1) (intersect clip frame)
                (io:blend-rect fb x0 y0 x1 y1 r g b (* a alpha))))
            (let ((image (getf layer :contents)))
              (when (and image (getf image :pixels))
                (io:blit-image fb (round x) (round y) (round bw) (round bh)
                               (coerce (getf image :pixels) '(simple-array (unsigned-byte 8) (*)))
                               (getf image :width) (getf image :height) (float alpha 1.0) inner)))
            (loop :for child :across (or (getf layer :sublayers) #())
                  :do (draw-layer fb layers child (- x bx) (- y by) inner alpha))))))))

(defun intersect (a b)
  (list (max (first a) (first b)) (max (second a) (second b))
        (min (third a) (third b)) (min (fourth a) (fourth b))))

(defun corner-radius (window)
  (case (window-level window)
    (0 12) (101 8) (20 18) (t 0)))

(defun shadowed-p (window)
  (member (window-level window) '(0 101)))

(defvar *damage* nil)

(defun damage (x0 y0 x1 y1)
  (setf *damage* (if *damage*
                     (list (min x0 (first *damage*)) (min y0 (second *damage*))
                           (max x1 (third *damage*)) (max y1 (fourth *damage*)))
                     (list x0 y0 x1 y1))))

(defun damage-window (window)
  (damage (- (window-x window) 16) (- (window-y window) 16)
          (+ (window-x window) (window-width window) 16) (+ (window-y window) (window-height window) 24)))

(defun damage-cursor ()
  (destructuring-bind (x y) *cursor*
    (damage x y (+ x 13) (+ y 20))))

(defun damage-all ()
  (damage 0 0 (io:framebuffer-width *framebuffer*) (io:framebuffer-height *framebuffer*)))

(defun redraw-after-wake (event device)
  (declare (ignore device))
  (when (and (eq event :woke) *framebuffer*)
    (sb-thread:with-mutex (*lock*)
      (damage-all)
      (render))))

(setf darterfly/devices:*device-hooks*
      (append (remove 'redraw-after-wake darterfly/devices:*device-hooks*) (list 'redraw-after-wake)))

(defun render ()
  (let* ((fb *framebuffer*)
         (whole (list 0 0 (io:framebuffer-width fb) (io:framebuffer-height fb)))
         (screen (intersect whole (or (shiftf *damage* nil) whole)))
         (io:*clip* screen))
    (when (and (< (first screen) (third screen)) (< (second screen) (fourth screen)))
      (let ((start (get-internal-real-time)))
        (render-rect fb screen)
        (darterfly/stats:note :frame-ms (/ (- (get-internal-real-time) start) (/ internal-time-units-per-second 1000.0)))))))

(defun render-rect (fb screen)
  (progn
    (destructuring-bind (r g b) (coerce +desktop+ 'list)
      (io:blend-rect fb (first screen) (second screen) (third screen) (fourth screen) r g b 1.0))
    (dolist (window (reverse (by-level *windows*)))
      (let ((client (and (visible-p window) (context-client (window-context window)))))
        (when (and client (root client))
          (let* ((radius (corner-radius window))
                 (x (window-x window)) (y (window-y window))
                 (w (window-width window)) (h (window-height window))
                 (saved (and (plusp radius)
                             (progn (when (shadowed-p window) (io:shadow-under fb x y w h))
                                    (io:save-corners fb x y w h radius)))))
            (draw-layer fb (layers client) (root client) x y (intersect screen (window-frame window)) 1.0)
            (when saved (io:restore-corners fb x y w h radius saved))))))
    (draw-cursor fb)
    (io:flush fb :x (first screen) :y (second screen)
                 :width (- (third screen) (first screen)) :height (- (fourth screen) (second screen)))))

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
        (damage-cursor)
        (when *drag*
          (let ((window (first *drag*)))
            (damage-window window)
            (incf (window-x window) (- nx x))
            (incf (window-y window) (- ny y))
            (damage-window window)))
        (setf *cursor* (list nx ny))
        (damage-cursor)))))

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
                     (damage-window window)
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

(defvar *last-click* (list 0 -100 -100 0))

(defun click-count (type x y)
  (if (eq type :left-mouse-down)
      (destructuring-bind (time lx ly count) *last-click*
        (let* ((now (get-internal-real-time))
               (count (if (and (< (- now time) (* 0.4 internal-time-units-per-second))
                               (< (abs (- x lx)) 5) (< (abs (- y ly)) 5))
                          (1+ count) 1)))
          (setf *last-click* (list now x y count))
          count))
      (fourth *last-click*)))

(defun click (window type x y)
  (let ((client (context-client (window-context window))))
    (post-event client (server:mouse-event type x y :timestamp (get-internal-real-time)
                                                    :window (window-id window)
                                                    :clicks (click-count type x y)
                                                    :wx (- x (window-x window)) :wy (- y (window-y window))))))

(defvar *shift* nil)
(defvar *control* nil)
(defvar *alt* nil)
(defvar *meta* nil)

(defparameter +force-quit+ "/System/Applications/Utilities/Force Quit.app/Contents/Programs/Force Quit")

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
            ((io:control-key-p code) (setf *control* (plusp value)))
            ((io:alt-key-p code) (setf *alt* (plusp value)))
            ((io:meta-key-p code) (setf *meta* (plusp value)))
            ((and (plusp value) (= code io:+key-esc+) *alt* *meta*)
             (ignore-errors (bsd:posix-spawn +force-quit+ (list "Force Quit") nil)))
            ((plusp value)
             (let ((char (io:key-character code *shift* *control*)))
               (when char
                 (post-event (key-client)
                             (server:key-event t code char :timestamp (get-internal-real-time) :location *cursor*
                               :modifiers (logior (if *control* 1 0) (if *shift* 2 0)
                                                  (if *alt* 4 0) (if *meta* 8 0)))))))))))

(defun hid-devices () (io:input-devices))

(defun drain (devices)
  (loop :for batch := (loop :for fd :in devices :append (io:read-events fd))
        :while batch
        :append batch))

(defun hid-loop ()
  (let ((devices (hid-devices)))
    (bsd:bsdthread-create (lambda () (collect-events devices)) "hid events")
    (loop
      (handler-case (hid-step)
        (error (e)
          (ignore-errors
           (with-open-file (s "/tmp/WindowServer.err" :direction :output :if-exists :append :if-does-not-exist :create)
             (format s "~a~%" e)
             (sb-debug:print-backtrace :stream s :count 15))))))))

(defvar *pending* nil)
(defvar *pending-lock* (sb-thread:make-mutex :name "hid events"))
(defvar *pending-ready* (sb-thread:make-waitqueue))

(defun collect-events (devices)
  (loop
    (let ((events (drain devices)))
      (when events (darterfly/power:note-activity))
      (if events
          (sb-thread:with-mutex (*pending-lock*)
            (setf *pending* (nconc *pending* events))
            (sb-thread:condition-broadcast *pending-ready*))
          (io:wait-for-events devices)))))

(defun take-events ()
  (sb-thread:with-mutex (*pending-lock*)
    (loop :until *pending* :do (sb-thread:condition-wait *pending-ready* *pending-lock*))
    (shiftf *pending* nil)))

(defun hid-step ()
  (let ((events (take-events)))
    (sb-thread:with-mutex (*lock*)
      (let ((before (list *cursor* (first *windows*) (and *drag* (window-x (first *drag*))) (and *drag* (window-y (first *drag*))))))
        (mapc #'pointer events)
        (mapc #'keyboard events)
        (unless (equal before (list *cursor* (first *windows*) (and *drag* (window-x (first *drag*))) (and *drag* (window-y (first *drag*)))))
          (render))))))

(defun apply-commit (client body)
  (clrhash (layers client))
  (loop :for (id . layer) :in (getf body :layers)
        :do (setf (gethash id (layers client)) layer))
  (setf (root client) (getf body :root)))

(defun register-client (message set)
  (sb-thread:with-mutex (*lock*)
    (%register-client message set)))

(defun %register-client (message set)
  (let ((port (mach:mach-port-allocate mach:*task* :receive))
        (context (incf *next-context*)))
    (mach:mach-port-move-member mach:*task* port set)
    (mach:mach-port-request-notification mach:*task* port :no-senders 1 port :make-send-once)
    (push (make-instance 'client :port port :context context
                                 :pid (getf (rest (mach:msgh-body message)) :pid)
                                 :events (car (first (mach:msgh-descriptors message))))
          *clients*)
    (reply message (list :context-id context) (list (cons port :make-send)))))

(defun reply (message body &optional descriptors)
  (mach:mach-msg-send (mach:make-message :remote-port (mach:msgh-remote-port message)
                                         :remote-disposition :move-send-once
                                         :body body :descriptors descriptors)))

(defun find-window (id) (find id *windows* :key #'window-id))

(defun create-window (message)
  (let* ((port (mach:mach-port-allocate mach:*task* :receive))
         (window (make-instance 'window :id (incf *next-window*) :port port
                                        :owner (bsd:task-pid (mach:msgh-audit message))))
         (body (rest (mach:msgh-body message))))
    (setf (window-width window) (getf body :width 0) (window-height window) (getf body :height 0))
    (setf *windows* (append *windows* (list window)))
    (reply message (list :window (window-id window)) (list (cons port :make-send)))))

(defun set-window-context (window context)
  (let ((window (find-window window)))
    (when window
      (setf (window-context window) context)
      (damage-window window))))

(defun apply-transaction (forms)
  (dolist (form forms)
    (destructuring-bind (op id &rest args) form
      (let ((window (find-window id)))
        (when window
          (damage-window window)
          (ecase op
            (:shape (setf (window-width window) (first args) (window-height window) (second args)))
            (:move (setf (window-x window) (round (first args)) (window-y window) (round (second args))))
            (:level (setf (window-level window) (first args)))
            (:order (let ((order (first args)))
                      (setf (ordered window) (not (eq order :out)))
                      (case order
                        (:above (setf *windows* (cons window (remove window *windows*))))
                        (:below (setf *windows* (append (remove window *windows*) (list window))))))))
          (damage-window window))))))

(defun client-of (port)
  (find port *clients* :key #'port))

(defun forget-client (port)
  (let ((client (client-of port)))
    (when client
      (dolist (w *windows*) (when (eql (window-context w) (context client)) (damage-window w)))
      (setf *clients* (remove client *clients*)
            *windows* (remove-if (lambda (w) (eql (window-context w) (context client))) *windows*))
      (mach:mach-port-mod-refs mach:*task* port :receive -1)
      (render))))

(defun commit-from (port body)
  (let ((client (client-of port)))
    (when client
      (dolist (w *windows*) (when (eql (window-context w) (context client)) (damage-window w)))
      (apply-commit client body)
      (render))))

(defun serve (render-server set)
  (loop
    (let* ((message (mach:mach-msg-receive set))
           (port (mach:msgh-local-port message))
           (body (mach:msgh-body message)))
      (cond ((= (mach:msgh-id message) +mach-notify-no-senders+)
             (sb-thread:with-mutex (*lock*) (forget-client port)))
            ((not (consp body)))
            ((eql port render-server)
             (when (eq (first body) :register-client)
               (register-client message set)))
            (t
             (case (first body)
               (:commit (sb-thread:with-mutex (*lock*) (commit-from port (rest body))))
               (:create-window (sb-thread:with-mutex (*lock*) (create-window message)))
               (:display-bounds
                (reply message (list :bounds (list 0 0 (io:framebuffer-width *framebuffer*) (io:framebuffer-height *framebuffer*)))))
               (:set-window-context
                (sb-thread:with-mutex (*lock*) (set-window-context (second body) (third body)) (render)))
               (:transaction
                (sb-thread:with-mutex (*lock*) (apply-transaction (second body)) (render)))))))))

(bsd:define-program "WindowServer" (argv envp)
  (setf *framebuffer* (io:open-framebuffer)
        *clients* nil
        *windows* nil
        *cursor* (list (floor (io:framebuffer-width *framebuffer*) 2)
                       (floor (io:framebuffer-height *framebuffer*) 2)))
  (damage-all)
  (render)
  (bsd:bsdthread-create #'hid-loop "hid")
  (bsd:bsdthread-create #'darterfly/power:dim-when-idle "dimming")
  (let ((set (mach:mach-port-allocate mach:*task* :port-set))
        (render-server (init:bootstrap-check-in "renderserver")))
    (dolist (name '("windowserver" "windowserver.active"))
      (let ((port (init:bootstrap-check-in name)))
        (when port (mach:mach-port-move-member mach:*task* port set))))
    (mach:mach-port-move-member mach:*task* render-server set)
    (darterfly/init:bootstrap-look-up "Session")
    (format t "WindowServer: ~dx~d, render server #x~x~%"
            (io:framebuffer-width *framebuffer*) (io:framebuffer-height *framebuffer*) render-server)
    (finish-output)
    (serve render-server set)))

(defun forget-windows ()
  (setf *lock* (sb-thread:make-mutex :name "WindowServer")
        *pending-lock* (sb-thread:make-mutex :name "hid events")
        *pending-ready* (sb-thread:make-waitqueue)
        *pending* nil *windows* nil *clients* nil *framebuffer* nil *drag* nil *damage* nil))

(pushnew 'forget-windows sb-ext:*save-hooks*)
