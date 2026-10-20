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
   (level :initform 0 :accessor window-level)
   (min-width :initform 280 :accessor min-width)
   (min-height :initform 180 :accessor min-height)
   (minimized :initform nil :accessor minimized)
   (title :initform "" :accessor window-title) (location :initform "" :accessor window-location)
   (question :initform nil :accessor window-question)
   (private :initform nil :accessor window-private) (transient :initform nil :accessor window-transient)
   (minimized-at :initform 0 :accessor minimized-at) (thumb :initform nil :accessor window-thumb)
   (content-revision :initform 0 :accessor window-content-revision)
   (unzoomed :initform nil :accessor unzoomed)
   (shadow :initform nil :accessor window-shadow)
   (shadow-size :initform nil :accessor window-shadow-size)))

(defun by-level (windows)
  (stable-sort (copy-list windows) #'> :key #'window-level))

(defvar *window-epoch* nil)
(defvar *window-revision* 0)
(defstruct flight window from to start (duration .28) target (display-position 0.0))
(defvar *flight* nil)
(defvar *motion-wakeup* nil)
(defvar *windows* nil)
(defvar *next-window* #x20)
(defvar *clients* nil)
(defvar *next-context* #x1000)
(defvar *framebuffer* nil)
(defvar *startup* nil)
(defvar *lock* (sb-thread:make-mutex :name "WindowServer"))
(defvar *cursor* (list 512 384))
(defvar *drag* nil)
(defvar *capture* nil)
(defvar *hover-window* nil)
(defvar *focused-window* nil)
(defparameter +title-height+ 26)

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

(defun resize-cursor (fb cx cy edges)
  (let* ((diagonal (= (length edges) 2))
         (mirror (or (and (member :right edges) (member :top edges))
                     (and (member :left edges) (member :bottom edges))))
         (vertical (and (not diagonal) (or (member :top edges) (member :bottom edges))))
         (lines (if diagonal '((-5 -5 5 5) (-5 -5 0 -5) (-5 -5 -5 0) (5 5 0 5) (5 5 5 0))
                    '((-7 0 7 0) (-7 0 -3 -4) (-7 0 -3 4) (7 0 3 -4) (7 0 3 4)))))
    (dolist (pass '(1 0))
      (dolist (line lines)
        (destructuring-bind (x0 y0 x1 y1) line
          (let ((steps (max 1 (abs (- x1 x0)) (abs (- y1 y0)))))
            (dotimes (i (1+ steps))
              (let* ((x (round (+ x0 (* (- x1 x0) (/ i steps)))))
                     (y (round (+ y0 (* (- y1 y0) (/ i steps))))))
                (when mirror (setf x (- x)))
                (when vertical (rotatef x y))
                (io:blend-rect fb (- (+ cx x) pass) (- (+ cy y) pass)
                               (+ cx x pass 1) (+ cy y pass 1) pass pass pass 1.0)))))))))

(defun draw-cursor (fb)
  (destructuring-bind (cx cy) *cursor*
    (let* ((window (window-at cx cy))
           (edges (if *drag* (unless (eq (second *drag*) :move) (second *drag*))
                      (and window (resize-edges-at window cx cy)))))
      (when edges (resize-cursor fb cx cy edges) (return-from draw-cursor nil)))
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
                    (and (<= x0 x) (< x x1) (<= y0 y) (< y y1)))))
           (by-level *windows*)))

(defun context-client (context)
  (find context *clients* :key #'context))

(defconstant +main-menu-level+ 24)

(defun key-window ()
  (find-if (lambda (w) (and (ordered w) (not (and *flight* (eq w (flight-window *flight*)))) (<= (window-level w) 0))) (by-level *windows*)))

(defun key-client ()
  (let ((window (key-window)))
    (and window (context-client (window-context window)))))

(defun visible-p (window)
  (and (ordered window) (not (and *flight* (eq window (flight-window *flight*))))
       (or (/= (window-level window) +main-menu-level+)
           (let ((key (key-window)))
             (and key (eql (owner key) (owner window)))))))

(defun draw-layer (fb layers id ox oy clip alpha &optional (scale 1))
  (let ((layer (gethash id layers)))
    (when layer
      (destructuring-bind (px py) (coerce (getf layer :position) 'list)
        (destructuring-bind (bx by bw bh) (coerce (getf layer :bounds) 'list)
          (let* ((px (* px scale)) (py (* py scale)) (bx (* bx scale)) (by (* by scale))
                 (bw (* bw scale)) (bh (* bh scale))
                 (x (+ ox (- px (/ bw 2))))
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
                  :do (draw-layer fb layers child (- x bx) (- y by) inner alpha scale))))))))

(defun intersect (a b)
  (list (max (first a) (first b)) (max (second a) (second b))
        (min (third a) (third b)) (min (fourth a) (fourth b))))

(defun corner-radius (window)
  (case (window-level window)
    (0 7) (101 7) (20 18) (t 0)))

(defun attached-menu-p (window)
  (and (= (window-level window) 101) (= (window-y window) 26)))

(defun shadowed-p (window)
  (member (window-level window) '(0 101)))

(defun rounded-distance (x y width height radius)
  (let* ((qx (- (abs (- x (/ width 2.0))) (- (/ width 2.0) radius)))
         (qy (- (abs (- y (/ height 2.0))) (- (/ height 2.0) radius))))
    (- (+ (sqrt (+ (expt (max qx 0.0) 2) (expt (max qy 0.0) 2)))
          (min (max qx qy) 0.0)) radius)))

(defun make-window-shadow (width height radius)
  (declare (optimize (speed 3)))
  (let* ((w (+ width 72)) (h (+ height 72))
         (pixels (make-array (* w h 4) :element-type '(unsigned-byte 8) :initial-element 0)))
    (dotimes (y h)
      (dotimes (x w)
        (let* ((near (max 0.0 (rounded-distance (- x 35.5) (- y 36.5) width height radius)))
               (far (max 0.0 (rounded-distance (- x 35.5) (- y 43.5) width height radius)))
               (alpha (round (* 255 (+ (* .18 (exp (/ (- (* near near)) 8.0)))
                                      (* .23 (exp (/ (- (* far far)) 128.0)))))))
               (at (* 4 (+ x (* y w)))))
          (setf (aref pixels at) (round (* 16 alpha) 255)
                (aref pixels (+ at 1)) (round (* 24 alpha) 255)
                (aref pixels (+ at 2)) (round (* 34 alpha) 255)
                (aref pixels (+ at 3)) alpha))))
    pixels))

(defun draw-window-shadow (fb window screen)
  (let ((size (list (window-width window) (window-height window))))
    (unless (equal size (window-shadow-size window))
      (setf (window-shadow window) (make-window-shadow (first size) (second size) (corner-radius window))
            (window-shadow-size window) size))
    (let ((w (+ 72 (first size))) (h (+ 72 (second size))))
      (io:blit-image fb (- (window-x window) 36) (- (window-y window) 36) w h (window-shadow window) w h
                     (cond ((attached-menu-p window) .75)
                           ((eq window *focused-window*) 1.0) (t .60))
                     (if (attached-menu-p window)
                         (intersect screen (list 0 (window-y window) (io:framebuffer-width fb) (io:framebuffer-height fb)))
                         screen)))))

(defvar *damage* nil)

(defun damage (x0 y0 x1 y1)
  (setf *damage* (if *damage*
                     (list (min x0 (first *damage*)) (min y0 (second *damage*))
                           (max x1 (third *damage*)) (max y1 (fourth *damage*)))
                     (list x0 y0 x1 y1))))

(defun damage-window (window)
  (damage (- (window-x window) 36) (- (window-y window) 36)
          (+ (window-x window) (window-width window) 36) (+ (window-y window) (window-height window) 36)))

(defun damage-cursor ()
  (destructuring-bind (x y) *cursor*
    (damage (- x 10) (- y 10) (+ x 20) (+ y 20))))

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
         (screen (intersect whole (if *startup* (progn (setf *damage* nil) whole) (or (shiftf *damage* nil) whole))))
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
                             (progn (when (shadowed-p window) (draw-window-shadow fb window screen))
                                    (io:save-corners fb x y w h radius)))))
            (draw-layer fb (layers client) (root client) x y (intersect screen (window-frame window)) 1.0)
            (when saved (io:restore-corners fb x y w h radius saved :top (not (attached-menu-p window))))))))
    (render-flight fb screen)
    (when *startup* (draw-startup fb))
    (unless *startup* (draw-cursor fb))
    (io:flush fb :x (first screen) :y (second screen)
                 :width (- (third screen) (first screen)) :height (- (fourth screen) (second screen)))))

(defconstant +ev-key+ 1)
(defconstant +ev-rel+ 2)
(defconstant +rel-x+ 0)
(defconstant +rel-y+ 1)
(defconstant +btn-left+ #x110)

(defconstant +ev-abs+ 3)
(defconstant +abs-max+ 32768)

(defun window-event (window type &rest values)
  (when window
    (post-event (context-client (window-context window))
                (list* :type type :window (window-id window) values))))

(defun dismiss-menus (&optional except preserve-questions)
  (let ((dismissed nil))
    (dolist (window *windows*)
      (when (and (= (window-level window) 101) (ordered window) (not (eq window except))
                 (not (and preserve-questions (window-question window))))
        (damage-window window)
        (setf (ordered window) nil dismissed t)
        (window-event window :menu-dismissed)))
    dismissed))

(defun update-focus ()
  (let ((next (key-window)))
    (unless (eq next *focused-window*)
      (let ((previous *focused-window*))
        (setf *focused-window* next)
        (when previous (damage-window previous) (window-event previous :window-deactivated))
        (when next (damage-window next) (window-event next :window-activated))
        (dismiss-menus nil t)
        ;; Application menu ownership changes even when neither window overlaps it.
        (when *framebuffer* (damage 0 0 (io:framebuffer-width *framebuffer*) 26))))))

(defun notify-pointer ()
  (destructuring-bind (x y) *cursor*
    (let ((next (unless *drag* (or *capture* (window-at x y)))))
      (unless (eq next *hover-window*)
        (when *hover-window* (click *hover-window* :mouse-exited x y))
        (setf *hover-window* next))
      (when next (click next :mouse-moved x y)))))

(defun notify-frame (window)
  (window-event window :window-frame-changed :frame
                (list (window-x window) (window-y window) (window-width window) (window-height window))))

(defun resize-edges-at (window x y)
  (when (zerop (window-level window))
    (let ((lx (- x (window-x window))) (ly (- y (window-y window))))
      (remove nil (list (cond ((< lx 5) :left) ((>= lx (- (window-width window) 5)) :right))
                        (cond ((< ly 5) :top) ((>= ly (- (window-height window) 5)) :bottom)))))))

(defun set-frame (window frame)
  (destructuring-bind (x y w h) frame
    (setf (window-x window) x (window-y window) y
          (window-width window) w (window-height window) h))
  (damage-window window)
  (notify-frame window))

(defun drag-frame (window mode original dx dy screen-width screen-height)
  (destructuring-bind (x y w h) original
    (if (eq mode :move)
        (list (max (- 100 w) (min (- screen-width 100) (+ x dx)))
              (max 26 (min (- screen-height 60) (+ y dy))) w h)
        (let ((right (+ x w)) (bottom (+ y h)))
          (when (member :left mode)
            (setf x (min (- right (min-width window)) (max 0 (+ x dx)))))
          (when (member :top mode)
            (setf y (min (- bottom (min-height window)) (max 26 (+ y dy)))))
          (when (member :right mode)
            (setf right (max (+ x (min-width window)) (min screen-width (+ right dx)))))
          (when (member :bottom mode)
            (setf bottom (max (+ y (min-height window)) (min (- screen-height 16) (+ bottom dy)))))
          (list x y (- right x) (- bottom y))))))

(defun move-cursor (nx ny)
  (let* ((fb *framebuffer*)
         (nx (max 0 (min (1- (io:framebuffer-width fb)) nx)))
         (ny (max 0 (min (1- (io:framebuffer-height fb)) ny))))
    (damage-cursor)
    (when *drag*
      (destructuring-bind (window mode sx sy original) *drag*
        (let ((frame (drag-frame window mode original (- nx sx) (- ny sy)
                                 (io:framebuffer-width fb) (io:framebuffer-height fb))))
          (unless (equal frame (list (window-x window) (window-y window) (window-width window) (window-height window)))
            (damage-window window)
            (setf (unzoomed window) nil)
            (set-frame window frame)))))
    (setf *cursor* (list nx ny))
    (damage-cursor)))

(defun pointer-down (x y)
  (when *startup* (finish-startup :input) (return-from pointer-down nil))
  (let ((window (window-at x y)))
    (setf *capture* nil *drag* nil)
    (when (and (or (null window) (not (member (window-level window) '(24 101))))
               (dismiss-menus))
      (return-from pointer-down nil))
    (when window
      (let* ((was-key (eq window (key-window)))
             (lx (- x (window-x window))) (ly (- y (window-y window)))
             (edges (resize-edges-at window x y)))
        (damage-window window)
        (setf *windows* (cons window (remove window *windows*)))
        (update-focus)
        (cond ((or edges (and (zerop (window-level window)) (< ly +title-height+) (> lx 76)))
               (setf *drag* (list window (or edges :move) x y
                                 (list (window-x window) (window-y window) (window-width window) (window-height window)))))
              ;; First click activates inactive content. Window buttons act directly.
              ((and (zerop (window-level window)) (not was-key) (>= ly +title-height+)) nil)
              (t (setf *capture* window) (click window :left-mouse-down x y)))))))

(defun pointer-up (x y)
  (let ((window (shiftf *capture* nil)))
    (when (and window (member window *windows*) (ordered window))
      (click window :left-mouse-up x y)))
  (setf *drag* nil))

(defun pointer (event)
  (let ((fb *framebuffer*))
    (cond ((and (= (io:event-type event) +ev-rel+) (member (io:event-code event) '(6 8)))
           (destructuring-bind (x y) *cursor*
             (let ((window (or (find-if (lambda (w) (and (= (window-level w) 101) (ordered w))) *windows*)
                               (window-at x y))))
               (when window
                 (post-event (context-client (window-context window))
                             (list :type :scroll-wheel :window (window-id window)
                                   :window-location (list (- x (window-x window)) (- y (window-y window)))
                                   :delta-x (if (= (io:event-code event) 6) (io:event-value event) 0)
                                   :delta-y (if (= (io:event-code event) 8) (io:event-value event) 0)))))))
          ((= (io:event-type event) +ev-rel+)
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
           (apply (if (plusp (io:event-value event)) #'pointer-down #'pointer-up) *cursor*)))))

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

(defvar *shift* nil)
(defvar *control* nil)
(defvar *alt* nil)
(defvar *meta* nil)

(defun click (window type x y)
  (let ((client (context-client (window-context window))))
    (post-event client (server:mouse-event type x y :timestamp (get-internal-real-time)
                                                    :window (window-id window)
                                                    :clicks (click-count type x y)
                                                    :modifiers (remove nil (list (and *shift* :shift) (and *control* :control) (and *alt* :alt) (and *meta* :meta)))
                                                    :wx (- x (window-x window)) :wy (- y (window-y window))))))


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
      (when (and *startup* (plusp value))
        (finish-startup :input) (return-from keyboard nil))
      (when (and *flight* (plusp value) (= code io:+key-esc+)
                 (not (find-if (lambda (w) (and (= (window-level w) 101) (ordered w))) *windows*)))
        (transition-window (flight-window *flight*) nil) (return-from keyboard nil))
      (when (and *drag* (plusp value) (= code io:+key-esc+))
        (let ((window (first *drag*)) (original (fifth *drag*)))
          (damage-window window) (set-frame window original) (setf *drag* nil))
        (return-from keyboard nil))
      (cond ((io:shift-key-p code) (setf *shift* (plusp value)))
            ((io:control-key-p code) (setf *control* (plusp value)))
            ((io:alt-key-p code) (setf *alt* (plusp value)))
            ((io:meta-key-p code) (setf *meta* (plusp value)))
            ((and (plusp value) (= code io:+key-esc+) *alt* *meta*)
             (ignore-errors (bsd:posix-spawn +force-quit+ (list "Force Quit") nil)))
            (t
             (let ((char (io:key-character code *shift* *control*)))
               (when char
                 (let ((popup (find-if (lambda (w) (and (= (window-level w) 101) (ordered w))) *windows*)))
                   (post-event (if popup (context-client (window-context popup)) (key-client))
                               (server:key-event (plusp value) code char :timestamp (get-internal-real-time) :location *cursor*
                                                 :modifiers (remove nil (list (and *shift* :shift) (and *control* :control)
                                                                             (and *alt* :alt) (and *meta* :meta)))))))))))))

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
      (let ((before (copy-list *cursor*)))
        (mapc #'pointer events)
        (unless (equal before *cursor*) (notify-pointer)))
      (mapc #'keyboard events)
      (when *damage* (render)))))

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
  (let* ((window (make-instance 'window :id (incf *next-window*) :port nil
                                        :owner (bsd:task-pid (mach:msgh-audit message))))
         (body (rest (mach:msgh-body message))))
    (setf (window-width window) (getf body :width 0) (window-height window) (getf body :height 0)
          (min-width window) (getf body :min-width 280) (min-height window) (getf body :min-height 180))
    (incf *window-revision*)
    (setf *windows* (append *windows* (list window)))
    (reply message (list :window (window-id window)))))

(defun set-window-context (window context)
  (let ((window (find-window window)))
    (when window
      (setf (window-context window) context)
      (damage-window window))))

(defun zoom-window (window)
  (let ((frame (or (unzoomed window)
                   (list 40 44 (- (io:framebuffer-width *framebuffer*) 80)
                         (- (io:framebuffer-height *framebuffer*) 160)))))
    (setf (unzoomed window) (unless (unzoomed window)
                             (list (window-x window) (window-y window) (window-width window) (window-height window))))
    (destructuring-bind (x y w h) frame
      (setf (window-x window) x (window-y window) y (window-width window) w (window-height window) h))
    (notify-frame window)))

(defun activate-application (name)
  (let ((windows (remove-if-not
                  (lambda (w)
                    (and (zerop (window-level w)) (or (ordered w) (minimized w))
                         (let ((process (bsd:pfind (owner w))))
                           (and process (string= name (bsd:proc-comm process)))))) *windows*)))
    (when windows
      (let ((window (or (find-if (lambda (w) (not (minimized w))) windows) (first windows))))
        (transition-window window nil)))
    (unless windows
      (let ((desktop (find-if (lambda (w)
                               (and (< (window-level w) 0)
                                    (let ((process (bsd:pfind (owner w))))
                                      (and process (string= name (bsd:proc-comm process)))))) *windows*)))
        (when desktop (window-event desktop :application-open) (setf windows (list desktop)))))
    (update-focus)
    (not (null windows))))

(defun apply-transaction (forms &optional caller)
  (dolist (form forms)
    (destructuring-bind (op id &rest args) form
      (let ((window (find-window id)))
        (when (and window (or (null caller) (eql caller (owner window))))
          (damage-window window)
          (ecase op
            (:minimize (transition-window window t :reduced-motion (first args)))
            (:zoom (zoom-window window))
            (:shape (setf (window-width window) (first args) (window-height window) (second args)))
            (:move (setf (window-x window) (round (first args)) (window-y window) (round (second args))))
            (:level (setf (window-level window) (first args)))
            (:order (let ((order (first args)))
                      (setf (ordered window) (not (eq order :out)) (minimized window) nil)
                      (case order
                        (:above (setf *windows* (cons window (remove window *windows*))))
                        (:below (setf *windows* (append (remove window *windows*) (list window))))))))
          (damage-window window)))))
  (update-focus))

(defun client-of (port)
  (find port *clients* :key #'port))

(defun forget-client (port)
  (let ((client (client-of port)))
    (when client
      (dolist (w *windows*)
        (when (eql (window-context w) (context client))
          (damage-window w)
          (when (window-port w) (mach:mach-port-mod-refs mach:*task* (window-port w) :receive -1))))
      (when (events client) (mach:mach-port-deallocate mach:*task* (events client)))
      (setf *clients* (remove client *clients*)
            *windows* (remove-if (lambda (w) (eql (window-context w) (context client))) *windows*))
      (when (and *capture* (not (member *capture* *windows*))) (setf *capture* nil))
      (when (and *hover-window* (not (member *hover-window* *windows*))) (setf *hover-window* nil))
      (when (and *drag* (not (member (first *drag*) *windows*))) (setf *drag* nil))
      (when (and *flight* (not (member (flight-window *flight*) *windows*))) (setf *flight* nil))
      (incf *window-revision*)
      (update-focus)
      (mach:mach-port-mod-refs mach:*task* port :receive -1)
      (render))))

(defun commit-from (port body)
  (let ((client (client-of port)))
    (when client
      (dolist (w *windows*)
        (when (eql (window-context w) (context client))
          (incf (window-content-revision w))
          (setf (window-thumb w) nil)
          (damage-window w)))
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
               (:activate-application
                (sb-thread:with-mutex (*lock*)
                  (reply message (list :activated (activate-application (second body)))) (render)))
               (:window-list
                (sb-thread:with-mutex (*lock*) (reply message (window-page (getf (rest body) :offset) (getf (rest body) :limit)))))
               (:window-metadata (sb-thread:with-mutex (*lock*) (metadata-from message)))
               (:restore-window
                (sb-thread:with-mutex (*lock*)
                  (reply message (list :restored (restore-handle (second body) :reduced-motion (getf (cddr body) :reduced-motion)))) (render)))
               (:window-thumbnail
                (sb-thread:with-mutex (*lock*)
                  (let ((w (handle-window (second body))))
                    (reply message (list :thumbnail (and w (member w (named-windows)) (minimized w) (thumbnail w)))))))
               (:display-bounds
                (reply message (list :bounds (list 0 0 (io:framebuffer-width *framebuffer*) (io:framebuffer-height *framebuffer*)))))
               (:set-window-context
                (sb-thread:with-mutex (*lock*) (let ((w (find-window (second body))) (c (context-client (third body)))
                  (pid (bsd:task-pid (mach:msgh-audit message))))
                  (when (and w c (eql pid (owner w)) (eql pid (pid c)))
                    (set-window-context (second body) (third body)))) (render)))
               (:transaction
                (sb-thread:with-mutex (*lock*) (apply-transaction (second body) (bsd:task-pid (mach:msgh-audit message))) (render)))))))))

(bsd:define-program "WindowServer" (argv envp)
  (setf *framebuffer* (io:open-framebuffer)
        *clients* nil
        *windows* nil
        *cursor* (list (floor (io:framebuffer-width *framebuffer*) 2)
                       (floor (io:framebuffer-height *framebuffer*) 2)))
  (setf *window-epoch* (list (get-universal-time) (random most-positive-fixnum))
        *motion-wakeup* (sb-thread:make-waitqueue :name "window motion"))
  (bsd:bsdthread-create #'window-motion-loop "window motion")
  (begin-startup)
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
    (when *startup* (bsd:bsdthread-create #'startup-loop "startup transition"))
    (serve render-server set)))

(defun forget-windows ()
  (setf *lock* (sb-thread:make-mutex :name "WindowServer")
        *pending-lock* (sb-thread:make-mutex :name "hid events")
        *pending-ready* (sb-thread:make-waitqueue)
        *pending* nil *windows* nil *clients* nil *framebuffer* nil *drag* nil *damage* nil
        *capture* nil *hover-window* nil *focused-window* nil *startup* nil *flight* nil))

(pushnew 'forget-windows sb-ext:*save-hooks*)
