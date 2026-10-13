(defpackage #:finch/kit
  (:use #:cl)
  (:local-nicknames (#:ca #:finch/ca) (#:text #:finch/text) (#:mach #:finch/mach) (#:server #:finch/server) (#:bsd #:finch/bsd)
                    (#:imageio #:finch/imageio))
  (:export #:responder #:view #:text-field #:button #:window #:make-window
           #:view-frame #:subviews #:add-subview #:needs-display #:draw #:mouse-down #:key-down
           #:content-view #:window-title #:first-responder #:show #:close-window #:run
           #:string-value #:font-size #:text-color #:title #:action #:background
           #:view-width #:view-height #:windows #:perform-on-main #:menu-bar #:*menus* #:*click-count* #:icon-view #:icon-path #:label #:remove-subviews
           #:window-level #:style #:set-window-title))
(in-package #:finch/kit)

(defclass responder () ())

(defclass view (responder)
  ((frame :initarg :frame :initform (vector 0 0 0 0) :accessor view-frame)
   (subviews :initform nil :accessor subviews)
   (superview :initform nil :accessor superview)
   (window :initform nil :accessor view-window)
   (layer :initform (ca:make-layer) :reader view-layer)
   (background :initarg :background :initform nil :accessor background)
   (dirty :initform t :accessor dirty)))

(defun view-width (view) (round (aref (view-frame view) 2)))
(defun view-height (view) (round (aref (view-frame view) 3)))

(defgeneric draw (view bitmap))
(defgeneric mouse-down (view x y))
(defgeneric key-down (view characters keycode))

(defmethod draw ((view view) bitmap)
  (let ((c (background view)))
    (when c (text:fill-bitmap bitmap (aref c 0) (aref c 1) (aref c 2) (aref c 3)))))

(defmethod mouse-down ((view view) x y)
  (declare (ignore x y))
  nil)

(defmethod key-down ((view view) characters keycode)
  (declare (ignore characters keycode))
  nil)

(defun window-of (view)
  (or (view-window view) (and (superview view) (window-of (superview view)))))

(defun add-subview (view subview)
  (setf (superview subview) view
        (subviews view) (append (subviews view) (list subview)))
  (needs-display subview)
  subview)

(defun needs-display (view)
  (setf (dirty view) t)
  view)

(defun display (view)
  (let ((layer (view-layer view)))
    (setf (ca:layer-frame layer) (view-frame view))
    (when (dirty view)
      (let ((w (max 1 (view-width view))) (h (max 1 (view-height view))))
        (let ((bitmap (text:make-bitmap w h)))
          (draw view bitmap)
          (setf (ca:layer-contents layer) (ca:image w h (text:bitmap-pixels bitmap)))))
      (setf (dirty view) nil))
    (setf (ca:layer-sublayers layer) (mapcar #'view-layer (subviews view)))
    (mapc #'display (subviews view))))

(defun view-at (view x y)
  (destructuring-bind (vx vy vw vh) (coerce (view-frame view) 'list)
    (when (and (<= vx x (+ vx vw)) (<= vy y (+ vy vh)))
      (let ((lx (- x vx)) (ly (- y vy)))
        (or (some (lambda (sub) (view-at sub lx ly)) (reverse (subviews view)))
            (list view lx ly))))))

(defclass text-field (view)
  ((string :initarg :string :initform "" :accessor string-value)
   (font-size :initarg :font-size :initform 13 :accessor font-size)
   (font-name :initarg :font-name :initform "SFNS" :accessor font-name)
   (text-color :initarg :text-color :initform #(0.0 0.0 0.0) :accessor text-color)))

(defmethod (setf string-value) :after (value (field text-field))
  (declare (ignore value))
  (needs-display field))

(defmethod draw ((field text-field) bitmap)
  (call-next-method)
  (let ((font (text:font (font-name field) (font-size field)))
        (c (text-color field)))
    (text:draw-string bitmap font (string-value field) 1 (text:font-ascent font) (aref c 0) (aref c 1) (aref c 2))))

(defclass button (view)
  ((title :initarg :title :initform "" :accessor title)
   (action :initarg :action :initform nil :accessor action)))

(defmethod draw ((button button) bitmap)
  (let* ((w (view-width button)) (h (view-height button))
         (font (text:font "SFNS" 13))
         (tw (text:string-width font (title button))))
    (text:fill-round-rect bitmap 0 0 w h 6 0.85 0.85 0.87)
    (text:fill-round-rect bitmap 1 1 (- w 2) (- h 2) 5 1.0 1.0 1.0)
    (text:draw-string bitmap font (title button) (round (- w tw) 2)
                      (round (+ (/ h 2) (/ (text:font-ascent font) 2.6))) 0.0 0.0 0.0)))

(defmethod mouse-down ((button button) x y)
  (declare (ignore x y))
  (when (action button) (funcall (action button) button))
  t)

(defparameter +title-height+ 28)
(defparameter +traffic-lights+
  '((:close 20 #(1.0 0.373 0.341)) (:minimize 40 #(0.996 0.737 0.18)) (:zoom 60 #(0.157 0.784 0.251))))

(defvar *click-count* 1)

(defclass icon-view (view)
  ((icon-path :initarg :icon-path :initform nil :accessor icon-path)
   (label :initarg :label :initform "" :accessor label)
   (label-color :initarg :label-color :initform #(0.0 0.0 0.0) :accessor label-color)))

(defvar *icons* (make-hash-table :test 'equal))
(defvar *icons-lock* (sb-thread:make-mutex :name "icons"))

(defun icon-pixels (path size)
  (sb-thread:with-mutex (*icons-lock*)
    (let ((key (cons path size)))
      (multiple-value-bind (pixels found) (gethash key *icons*)
        (if found pixels (setf (gethash key *icons*) (ignore-errors (imageio:icon path size))))))))

(defmethod draw ((view icon-view) bitmap)
  (let* ((w (view-width view))
         (size (min 64 (- w 8)))
         (x0 (round (- w size) 2))
         (pixels (and (icon-path view) (icon-pixels (icon-path view) size)))
         (out (text:bitmap-pixels bitmap))
         (bw (text:bitmap-width bitmap)))
    (when pixels
      (dotimes (y size)
        (dotimes (x size)
          (let ((at (* 4 (+ x (* y size)))) (to (* 4 (+ x0 x (* y bw)))))
            (when (< (+ to 3) (length out))
              (dotimes (c 4) (setf (aref out (+ to c)) (aref pixels (+ at c)))))))))
    (let* ((font (text:font "SFNS" 12))
           (label (label view))
           (c (label-color view)))
      (text:draw-string bitmap font label (max 0 (round (- w (text:string-width font label)) 2))
                        (+ size 16) (aref c 0) (aref c 1) (aref c 2)))))

(defun remove-subviews (view)
  (setf (subviews view) nil)
  (needs-display view))

(defclass theme-frame (view)
  ((title :initarg :title :initform "" :accessor title)))

(defmethod draw ((frame theme-frame) bitmap)
  (let* ((w (view-width frame))
         (font (text:font "SFNS" 13))
         (title (title frame)))
    (text:fill-bitmap bitmap 0.93 0.93 0.93 1.0)
    (text:fill-rect bitmap 0 0 w +title-height+ 0.85 0.85 0.85)
    (loop :for (nil cx color) :in +traffic-lights+
          :do (text:fill-ellipse bitmap cx 14 6 6 (aref color 0) (aref color 1) (aref color 2)))
    (text:draw-string bitmap font title (round (- w (text:string-width font title)) 2) 19 0.2 0.2 0.2)))

(defclass window ()
  ((title :initarg :title :initform "" :accessor window-title)
   (x :initarg :x :initform 100 :accessor window-x)
   (y :initarg :y :initform 100 :accessor window-y)
   (width :initarg :width :initform 400 :accessor window-width)
   (height :initarg :height :initform 300 :accessor window-height)
   (context :initform nil :accessor window-context)
   (id :initform nil :accessor window-id)
   (frame-view :accessor frame-view)
   (content :accessor content-view)
   (first-responder :initform nil :accessor first-responder)
   (style :initarg :style :initform :titled :reader style)
   (level :initarg :level :initform :normal :reader window-level)))

(defclass application ()
  ((windows :initform nil :accessor app-windows)
   (main :initform nil :accessor app-main)
   (menu :initform nil :accessor app-menu)
   (lock :initform (sb-thread:make-mutex :name "application") :reader app-lock)))

(bsd:define-process-variable *application* (make-instance 'application))

(defun windows () (app-windows *application*))

(defun make-window (&rest initargs &key background &allow-other-keys)
  (let* ((window (apply #'make-instance 'window :allow-other-keys t initargs))
         (borderless (eq (style window) :borderless))
         (frame (if borderless
                    (make-instance 'view :frame (vector 0 0 (window-width window) (window-height window)))
                    (make-instance 'theme-frame :title (window-title window)
                                                :frame (vector 0 0 (window-width window) (window-height window)))))
         (content (make-instance 'view :background (or background #(1.0 1.0 1.0 1.0))
                                       :frame (if borderless
                                                  (vector 0 0 (window-width window) (window-height window))
                                                  (vector 12 40 (- (window-width window) 24)
                                                          (- (window-height window) 52))))))
    (setf (view-window frame) window
          (frame-view window) frame
          (content-view window) content)
    (add-subview frame content)
    window))

(defun set-window-title (window title)
  (setf (window-title window) title)
  (when (typep (frame-view window) 'theme-frame)
    (setf (title (frame-view window)) title)
    (needs-display (frame-view window))))

(defun commit (window)
  (display (frame-view window))
  (ca:commit (window-context window)))

(bsd:define-process-variable *run-set* nil)

(defun listen-to (window)
  (when *run-set*
    (mach:mach-port-move-member mach:*task* (ca:context-events (window-context window)) *run-set*)))

(bsd:define-process-variable *menus* nil)

(defun menu-bar (titles)
  (let* ((font (text:font "SFNS" 14))
         (positions (loop :with x := 14
                          :for title :in titles
                          :collect (prog1 x (incf x (+ 20 (round (text:string-width font title)))))))
         (width (+ (car (last positions)) 20 (round (text:string-width font (car (last titles))))))
         (bitmap (text:make-bitmap width 24))
         (context (ca:context-create))
         (layer (ca:make-layer)))
    (loop :for title :in titles :for x :in positions
          :do (text:draw-string bitmap font title x 17 0.0 0.0 0.0))
    (setf (ca:layer-frame layer) (vector 0 0 width 24)
          (ca:layer-contents layer) (ca:image width 24 (text:bitmap-pixels bitmap))
          (ca:context-layer context) layer)
    (ca:commit context)
    (ca:window-create context 0 0 width 24 :level :main-menu)
    context))

(defun show (window)
  (unless (app-menu *application*)
    (setf (app-menu *application*)
          (menu-bar (or *menus* (list (bsd:proc-comm bsd:*proc*) "File" "Edit" "View" "Window" "Help")))))
  (unless (window-context window)
    (setf (window-context window) (ca:context-create))
    (setf (ca:context-layer (window-context window)) (view-layer (frame-view window))))
  (commit window)
  (unless (window-id window)
    (setf (window-id window)
          (ca:window-create (window-context window) (window-x window) (window-y window)
                            (window-width window) (window-height window) :level (window-level window))))
  (unless (member window (app-windows *application*))
    (push window (app-windows *application*))
    (listen-to window))
  window)

(defun close-window (window)
  (when (window-id window)
    (ca:transaction-commit (list (list "OrderWindow" (window-id window) 0 0))))
  (setf (app-windows *application*) (remove window (app-windows *application*))))

(defun any-dirty (view)
  (or (dirty view) (some #'any-dirty (subviews view))))

(defun window-mouse-down (window x y)
  (if (and (eq (style window) :titled) (< y +title-height+))
      (loop :for (name cx) :in +traffic-lights+
            :when (and (eq name :close) (<= (abs (- x cx)) 7) (<= (abs (- y 14)) 7))
              :do (close-window window))
      (let ((hit (view-at (content-view window) x y)))
        (when hit
          (destructuring-bind (view lx ly) hit
            (setf (first-responder window) view)
            (mouse-down view lx ly))))))

(defun window-key-down (window characters keycode)
  (let ((responder (or (first-responder window) (content-view window))))
    (key-down responder characters keycode)))

(defun main-port ()
  (sb-thread:with-mutex ((app-lock *application*))
    (or (app-main *application*)
        (setf (app-main *application*) (mach:mach-port-allocate mach:*task* :receive)))))

(defun perform-on-main (function)
  (let ((port (main-port)))
    (mach:mach-port-insert-right mach:*task* port port :make-send)
    (mach:mach-msg-send (mach:make-message :remote-port port :remote-disposition :move-send :body function))))

(defun commit-dirty ()
  (dolist (window (windows))
    (when (any-dirty (frame-view window))
      (commit window))))

(defun run ()
  (let ((set (mach:mach-port-allocate mach:*task* :port-set)))
    (setf *run-set* set)
    (mach:mach-port-move-member mach:*task* (main-port) set)
    (dolist (window (windows))
      (mach:mach-port-move-member mach:*task* (ca:context-events (window-context window)) set))
    (loop
      (let ((message (mach:mach-msg-receive set)))
        (if (eql (mach:msgh-local-port message) (main-port))
            (progn (funcall (mach:msgh-body message)) (commit-dirty))
            (dispatch message))))))

(defun dispatch (message)
  (let ((window (find (mach:msgh-local-port message) (windows)
                      :key (lambda (w) (ca:context-events (window-context w)))))
        (event (server:decode-event (mach:msgh-body message))))
    (when window
      (case (server:event-type event)
        (:left-mouse-down
         (destructuring-bind (x y) (server:event-window-location event)
           (let ((*click-count* (or (server:event-value event :mouse-event-click-state) 1)))
             (window-mouse-down window (round x) (round y)))))
        (:key-down
         (let ((char (server:event-character event)))
           (when char
             (window-key-down window (string char) (server:event-value event :keyboard-event-keycode))))))
      (when (member window (windows))
        (when (any-dirty (frame-view window))
          (commit window))))))
