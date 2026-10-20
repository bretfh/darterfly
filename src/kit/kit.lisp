(defpackage #:darterfly/kit
  (:use #:cl)
  (:local-nicknames (#:layer #:darterfly/layer) (#:text #:darterfly/text) (#:mach #:darterfly/mach) (#:server #:darterfly/server) (#:bsd #:darterfly/bsd)
                   (#:imageio #:darterfly/imageio))
  (:export #:resumed #:resume #:responder #:view #:text-field #:button #:window #:make-window
           #:view-frame #:subviews #:add-subview #:needs-display #:draw #:mouse-down #:key-down #:key-up #:scroll-wheel
           #:content-view #:window-title #:first-responder #:show #:close-window #:run
           #:string-value #:font-size #:text-color #:title #:action #:background
           #:view-width #:view-height #:windows #:perform-on-main #:menu-bar #:*menus* #:*click-count* #:icon-view #:icon-path #:label #:remove-subviews
           #:open-application #:mouse-up #:mouse-moved #:mouse-exited #:activate #:focusable-p #:focused-p #:focus-changed #:resize-view #:*key-modifiers*
           #:theme-color #:fill-surface #:ui-font #:paint-outset #:draw-rgba #:button-role #:button-enabled #:window-level #:style #:set-window-title #:standard-menus #:terminate))
(in-package #:darterfly/kit)
(defvar *choice-panel* nil)
(export '(window-location set-window-location))

(defparameter *ui-font* "Nunito-Regular")

(defun ui-font (&optional (size 12) (weight :regular))
  (text:font (ecase weight (:regular "Nunito-Regular")
                          (:semibold "Nunito-SemiBold") (:bold "Nunito-Bold")) size))

(defun rgb8 (r g b &optional (a 255))
  (map 'vector (lambda (v) (/ v 255.0)) (vector r g b a)))

(defparameter *theme-colors*
  (list :paper (rgb8 243 243 241) :surface (rgb8 236 237 234)
        :sidebar (rgb8 224 226 223) :ink (rgb8 53 53 53)
        :muted (rgb8 96 96 94) :selection (rgb8 211 212 210)
        :edge (rgb8 121 123 122) :focus (rgb8 94 98 97)
        :selection-edge (rgb8 100 104 103) :accent (rgb8 97 101 100)
        :accent-pressed (rgb8 73 77 76) :hover-edge (rgb8 94 98 97)
        :button-hover-top (rgb8 249 249 247) :button-hover-bottom (rgb8 235 236 233)
        :button-pressed-top (rgb8 201 203 201) :button-pressed-bottom (rgb8 222 223 220)
        :track (rgb8 199 201 198)
        :button-top (rgb8 247 247 244) :button-bottom (rgb8 225 227 224)
        :primary-top (rgb8 102 106 105) :primary-bottom (rgb8 79 83 82)
        :caution-top (rgb8 128 91 40) :caution-bottom (rgb8 104 72 32)
        :danger-top (rgb8 148 78 59) :danger-bottom (rgb8 121 62 48)
        :light-ink (rgb8 250 250 247) :disabled (rgb8 228 229 226)
        :disabled-ink (rgb8 146 146 146)))

(defun theme-color (role)
  (or (getf *theme-colors* role) (error "Unknown UI color role: ~s" role)))

(defun fill-surface (bitmap &optional (role :paper))
  (apply #'text:fill-bitmap bitmap (coerce (theme-color role) 'list)))

(defun rounded-gradient (bitmap x y width height radius top bottom)
  "Composite a vertical color ramp through the existing antialiased round-rect mask."
  (when (and (plusp width) (plusp height))
    (let* ((mask (text:make-bitmap width height))
           (pixels (text:bitmap-pixels bitmap))
           (stride (text:bitmap-width bitmap)))
      (text:fill-round-rect mask 0 0 width height radius 1.0 1.0 1.0)
      (dotimes (dy height)
        (let ((fraction (/ dy (max 1 (1- height)))))
          (dotimes (dx width)
            (when (and (<= 0 (+ x dx)) (< (+ x dx) stride)
                       (<= 0 (+ y dy)) (< (+ y dy) (text:bitmap-height bitmap)))
              (let* ((alpha (/ (aref (text:bitmap-pixels mask) (+ 3 (* 4 (+ dx (* dy width))))) 255.0))
                     (at (* 4 (+ x dx (* (+ y dy) stride)))))
                (dotimes (c 3)
                  (let ((value (+ (aref top c) (* fraction (- (aref bottom c) (aref top c))))))
                    (setf (aref pixels (+ at c))
                          (round (+ (* 255 alpha value) (* (- 1 alpha) (aref pixels (+ at c))))))))
                (setf (aref pixels (+ at 3))
                      (round (+ (* 255 alpha) (* (- 1 alpha) (aref pixels (+ at 3))))))))))))))

(defclass responder () ())

(defclass view (responder)
  ((frame :initarg :frame :initform (vector 0 0 0 0) :accessor view-frame)
   (subviews :initform nil :accessor subviews)
   (superview :initform nil :accessor superview)
   (window :initform nil :accessor view-window)
   (layer :initform (layer:make-layer) :reader view-layer)
   (background :initarg :background :initform nil :accessor background)
   (dirty :initform t :accessor dirty)
   (focused :initform nil :accessor focused-p)))

(defmethod initialize-instance :after ((view view) &key)
  ;; Layout owns its geometry, even when an app supplies a literal/shared vector.
  (setf (slot-value view 'frame) (copy-seq (view-frame view))))

(defmethod (setf view-frame) :around (frame (view view))
  (call-next-method (copy-seq frame) view))

(defun view-width (view) (round (aref (view-frame view) 2)))
(defun view-height (view) (round (aref (view-frame view) 3)))

(defgeneric draw (view bitmap))
(defgeneric mouse-down (view x y))
(defgeneric key-down (view characters keycode))
(defgeneric key-up (view characters keycode)
  (:method ((view view) characters keycode) (declare (ignore characters keycode)) nil))
(defgeneric cancel-key (view) (:method ((view view)) nil))
(defgeneric keyboard-target (view) (:method ((view view)) view))
(defgeneric scroll-wheel (view dx dy)
  (:method ((view view) dx dy)
    (when (superview view) (scroll-wheel (superview view) dx dy))))

(defmethod draw ((view view) bitmap)
  (let ((c (background view)))
    (when c (text:fill-bitmap bitmap (aref c 0) (aref c 1) (aref c 2) (aref c 3)))))

(defmethod mouse-down ((view view) x y)
  (declare (ignore x y))
  nil)

(defmethod key-down ((view view) characters keycode)
  (declare (ignore characters keycode))
  nil)

(defvar *key-modifiers* nil)

(defgeneric open-application (view)
  (:method ((view view)) (mapc #'open-application (subviews view))))

(defgeneric mouse-up (view x y) (:method ((view view) x y) (declare (ignore x y)) nil))
(defgeneric mouse-moved (view x y) (:method ((view view) x y) (declare (ignore x y)) nil))
(defgeneric mouse-exited (view) (:method ((view view)) nil))
(defgeneric cancel-pointer (view) (:method ((view view)) (mouse-exited view)))
(defgeneric focusable-p (view) (:method ((view view)) nil))
(defgeneric focus-changed (view) (:method ((view view)) (needs-display view)))
(defgeneric activate (view))

(defun inside-view-p (view x y)
  (and (<= 0 x) (< x (view-width view)) (<= 0 y) (< y (view-height view))))

(defgeneric resize-view (view width height))
(defmethod resize-view ((view view) width height)
  ;; A child that fills its parent stays attached to both opposing edges.
  ;; Applications can specialize this generic for intrinsic/reflowing layouts.
  (let ((old-width (view-width view)) (old-height (view-height view)))
    (dolist (child (subviews view))
      (let ((frame (view-frame child)))
        (resize-view child
                     (if (= (+ (aref frame 0) (view-width child)) old-width)
                         (max 1 (- width (aref frame 0))) (view-width child))
                     (if (= (+ (aref frame 1) (view-height child)) old-height)
                         (max 1 (- height (aref frame 1))) (view-height child)))))
    (setf (aref (view-frame view) 2) width (aref (view-frame view) 3) height)
    (needs-display view)))

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

(defgeneric paint-outset (view)
  (:method ((view view)) 0))

(defun display (view)
  (let* ((layer (view-layer view)) (outset (paint-outset view))
         (frame (view-frame view)) (w (+ (max 1 (view-width view)) (* 2 outset)))
         (h (+ (max 1 (view-height view)) (* 2 outset))))
    ;; Painting may extend beyond a control. Its layout and hit target never move.
    (setf (layer:layer-frame layer) (vector (- (aref frame 0) outset) (- (aref frame 1) outset) w h))
    (when (dirty view)
      (let ((bitmap (text:make-bitmap w h)))
        (draw view bitmap)
        (setf (layer:layer-contents layer) (layer:image w h (text:bitmap-pixels bitmap))))
      (setf (dirty view) nil))
    (setf (layer:layer-sublayers layer) (mapcar #'view-layer (subviews view)))
    (dolist (child (subviews view))
      (display child)
      (when (plusp outset)
        (let ((frame (layer:layer-frame (view-layer child))))
          (incf (aref frame 0) outset) (incf (aref frame 1) outset)
          (setf (layer:layer-frame (view-layer child)) frame))))))

(defun draw-rgba (bitmap pixels width height x y)
  (let ((out (text:bitmap-pixels bitmap)) (bw (text:bitmap-width bitmap)) (bh (text:bitmap-height bitmap)))
    (dotimes (dy height)
      (dotimes (dx width)
        (when (and (<= 0 (+ x dx)) (< (+ x dx) bw) (<= 0 (+ y dy)) (< (+ y dy) bh))
          (let* ((from (* 4 (+ dx (* dy width)))) (to (* 4 (+ x dx (* (+ y dy) bw))))
                 (keep (- 255 (aref pixels (+ from 3)))))
            (dotimes (c 4)
              (setf (aref out (+ to c)) (min 255 (+ (aref pixels (+ from c))
                                                  (round (* keep (aref out (+ to c))) 255)))))))))))

(defun focus-outline (bitmap width height radius)
  (let* ((hole (text:make-bitmap width height)) (out (text:bitmap-pixels bitmap)))
    (apply #'text:fill-round-rect bitmap 0 0 width height (+ radius 4) (coerce (theme-color :focus) 'list))
    (text:fill-round-rect hole 2 2 (- width 4) (- height 4) (+ radius 2) 1.0 1.0 1.0)
    (dotimes (i (* width height))
      (let ((keep (- 255 (aref (text:bitmap-pixels hole) (+ (* i 4) 3)))))
        (dotimes (c 4) (setf (aref out (+ (* i 4) c)) (round (* keep (aref out (+ (* i 4) c))) 255)))))))

(defun view-at (view x y)
  (destructuring-bind (vx vy vw vh) (coerce (view-frame view) 'list)
    (when (and (<= vx x) (< x (+ vx vw)) (<= vy y) (< y (+ vy vh)))
      (let ((lx (- x vx)) (ly (- y vy)))
        (or (some (lambda (sub) (view-at sub lx ly)) (reverse (subviews view)))
            (list view lx ly))))))

(defclass text-field (view)
  ((string :initarg :string :initform "" :accessor string-value)
   (font-size :initarg :font-size :initform 13 :accessor font-size)
   (font-name :initarg :font-name :initform *ui-font* :accessor font-name)
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
   (action :initarg :action :initform nil :accessor action)
   (role :initarg :role :initform :secondary :accessor button-role)
   (enabled :initarg :enabled :initform t :accessor button-enabled)
   (hovered :initform nil :accessor button-hovered)
   (armed :initform nil :accessor button-armed)
   (key :initform nil :accessor button-key)))

(defmethod paint-outset ((button button)) 4)

(defmethod focusable-p ((button button)) (button-enabled button))
(defmethod (setf button-enabled) :after (value (button button))
  (unless value (cancel-pointer button))
  (needs-display button))
(defmethod (setf button-role) :after (value (button button))
  (declare (ignore value)) (needs-display button))

(defun tint-color (color amount)
  (map 'vector (lambda (value) (max 0.0 (min 1.0 (+ value amount)))) color))

(defmethod draw ((button button) bitmap)
  (let* ((w (view-width button)) (h (view-height button))
         (font (ui-font 12 (if (eq (button-role button) :secondary) :semibold :bold))) (tw (text:string-width font (title button)))
         (enabled (button-enabled button)) (role (button-role button))
         (top (theme-color (if enabled (ecase role (:secondary :button-top) (:primary :primary-top)
                                           (:caution :caution-top) (:danger :danger-top)) :disabled)))
         (bottom (theme-color (if enabled (ecase role (:secondary :button-bottom) (:primary :primary-bottom)
                                              (:caution :caution-bottom) (:danger :danger-bottom)) :disabled)))
         (ink (theme-color (cond ((not enabled) :disabled-ink) ((eq role :secondary) :ink) (t :light-ink))))
         (edge (if (not enabled) (rgb8 204 204 204)
                   (if (eq role :secondary) (theme-color :edge) (rgb8 70 74 73))))
         (radius (min 13 (floor h 2))))
    (when (and enabled (button-hovered button))
      (setf edge (theme-color :hover-edge))
      (if (button-armed button)
          (if (eq role :secondary)
              (setf top (theme-color :button-pressed-top) bottom (theme-color :button-pressed-bottom))
              (setf top (tint-color bottom -0.04) bottom (tint-color top 0.02)))
          (if (eq role :secondary)
              (setf top (theme-color :button-hover-top) bottom (theme-color :button-hover-bottom))
              (setf top (tint-color top 0.02) bottom (tint-color bottom 0.02)))))
    (let* ((window (window-of button))
           (ring (and enabled (focused-p button)
                      (or (null window) (not (typep (frame-view window) 'theme-frame))
                          (frame-active (frame-view window))))))
      (when ring (focus-outline bitmap (+ w 8) (+ h 8) radius))
      (unless (and enabled (button-armed button) (button-hovered button))
        (text:fill-round-rect bitmap 4 5 w h radius .17 .17 .17 .17))
      (apply #'text:fill-round-rect bitmap 4 4 w h radius (coerce edge 'list))
      (rounded-gradient bitmap 5 5 (- w 2) (- h 2) (max 0 (1- radius)) top bottom))
    (text:draw-string bitmap font (title button) (+ 4 (round (- w tw) 2))
                      (+ 4 (round (+ (/ (- h (+ (text:font-ascent font) (text:font-descent font))) 2)
                                    (text:font-ascent font))))
                      (aref ink 0) (aref ink 1) (aref ink 2))))

(defmethod activate ((button button))
  (setf (button-armed button) nil)
  (needs-display button)
  (when (and (button-enabled button) (action button)) (funcall (action button) button)))

(defmethod mouse-down ((button button) x y)
  (when (button-enabled button)
    (setf (button-armed button) t (button-hovered button) (inside-view-p button x y))
    (needs-display button))
  t)

(defmethod mouse-moved ((button button) x y)
  (let ((hover (and (button-enabled button) (inside-view-p button x y))))
    (unless (eql hover (button-hovered button))
      (setf (button-hovered button) hover) (needs-display button))))

(defmethod mouse-exited ((button button))
  (when (button-hovered button) (setf (button-hovered button) nil) (needs-display button)))

(defmethod cancel-pointer ((button button))
  (setf (button-armed button) nil (button-hovered button) nil (button-key button) nil)
  (needs-display button))

(defmethod mouse-up ((button button) x y)
  (let ((activate (and (button-armed button) (inside-view-p button x y))))
    (setf (button-armed button) nil)
    (mouse-moved button x y)
    (needs-display button)
    (when activate (activate button))))

(defmethod cancel-key ((button button))
  (when (button-key button) (cancel-pointer button)))

(defmethod key-down ((button button) characters keycode)
  (declare (ignore characters))
  (cond ((= keycode 1) (cancel-pointer button))
        ((and (button-enabled button) (member keycode '(28 57)) (not (button-armed button)))
         (setf (button-key button) keycode (button-armed button) t (button-hovered button) t)
         (needs-display button))))

(defmethod key-up ((button button) characters keycode)
  (declare (ignore characters))
  (when (eql keycode (button-key button))
    (setf (button-key button) nil (button-armed button) nil (button-hovered button) nil)
    (needs-display button)
    (when (button-enabled button) (activate button))))

(defparameter +title-height+ 26)
(defparameter +traffic-lights+
  (list (list :close 16 (rgb8 185 140 102))
        (list :minimize 38 (rgb8 185 185 185))
        (list :zoom 60 (rgb8 139 168 200))))

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
    (let* ((font (text:font *ui-font* 12))
           (label (label view))
           (c (label-color view)))
      (text:draw-string bitmap font label (max 0 (round (- w (text:string-width font label)) 2))
                        (+ size 16) (aref c 0) (aref c 1) (aref c 2)))))

(defun descendant-p (candidate parent)
  (and candidate (or (eq candidate parent) (descendant-p (superview candidate) parent))))

(defun remove-subviews (view)
  (let ((window (window-of view)))
    (when window
      (when (descendant-p (first-responder window) view) (set-key-focus window nil))
      (when (descendant-p (capture-view window) view)
        (cancel-pointer (capture-view window)) (setf (capture-view window) nil))
      (when (descendant-p (hover-view window) view)
        (mouse-exited (hover-view window)) (setf (hover-view window) nil))))
  (dolist (child (subviews view)) (setf (superview child) nil))
  (setf (subviews view) nil)
  (needs-display view))

(defclass theme-frame (view)
  ((title :initarg :title :initform "" :accessor title)
   (active :initform t :accessor frame-active)
   (hover :initform nil :accessor chrome-hover)
   (pressed :initform nil :accessor chrome-pressed)))

(defun chrome-control-at (x y)
  (when (<= 2 y 24)
    (loop for (name cx) in +traffic-lights+
          when (< (abs (- x cx)) 11) return name)))

(defun chrome-symbol (bitmap name cx color)
  ;; All marks share a 6 x 6 box centered on the circle. Half-pixel centers
  ;; give the odd-width strokes equal weight on both sides at native scale.
  (destructuring-bind (r g b a) (coerce color 'list)
    (declare (ignore a))
    (case name
      (:close (loop for d from -2 to 2 do
                (text:fill-rect bitmap (+ cx d) (+ 13 d) 1 1 r g b)
                (text:fill-rect bitmap (+ cx d) (- 13 d) 1 1 r g b)))
      (:minimize (text:fill-rect bitmap (- cx 2) 13 5 1 r g b))
      (:zoom (text:fill-rect bitmap (- cx 2) 13 5 1 r g b)
             (text:fill-rect bitmap cx 11 1 5 r g b)))))

(defmethod draw ((frame theme-frame) bitmap)
  (let* ((w (view-width frame)) (active (frame-active frame))
         (font (ui-font 12 :bold)) (title (title frame)))
    (fill-surface bitmap)
    (rounded-gradient bitmap 0 0 w +title-height+ 0
                      (if active (rgb8 222 222 222) (rgb8 234 232 228))
                      (if active (rgb8 196 196 196) (rgb8 218 215 210)))
    (text:fill-rect bitmap 0 (1- +title-height+) w 1 0.67 0.67 0.67)
    (loop for (name cx color) in +traffic-lights+
          for hovered = (eq name (chrome-hover frame))
          for pressed = (and hovered (eq name (chrome-pressed frame)))
          for face = (if active color (rgb8 193 190 185))
          do (when (and active hovered)
               (text:fill-ellipse bitmap (+ cx 0.5) 13.5 7 7 0.25 0.24 0.22 0.13)
               (setf face (tint-color face (if pressed -0.12 0.045))))
             (text:fill-ellipse bitmap (+ cx 0.5) 13.5 5.5 5.5
                                (aref face 0) (aref face 1) (aref face 2))
             (when (and active (chrome-hover frame)) (chrome-symbol bitmap name cx (theme-color :ink))))
    (let ((ink (theme-color (if active :ink :muted))))
      (text:draw-string bitmap font title (round (- w (text:string-width font title)) 2) 18
                        (aref ink 0) (aref ink 1) (aref ink 2)))))

(defclass window ()
  ((title :initarg :title :initform "" :accessor window-title)
   (location :initarg :location :initform "" :accessor window-location)
   (private :initarg :private :initform nil :reader window-private)
   (transient :initarg :transient :initform nil :reader window-transient)
   (question :initarg :question :initform nil :reader window-question)
   (x :initarg :x :initform 100 :accessor window-x)
   (y :initarg :y :initform 100 :accessor window-y)
   (width :initarg :width :initform 400 :accessor window-width)
   (height :initarg :height :initform 300 :accessor window-height)
   (min-width :initarg :min-width :initform 280 :reader min-width)
   (min-height :initarg :min-height :initform 180 :reader min-height)
   (context :initform nil :accessor window-context)
   (id :initform nil :accessor window-id)
   (frame-view :accessor frame-view)
   (content :accessor content-view)
   (content-insets :initarg :content-insets :initform #(12 40 12 12) :reader content-insets)
   (first-responder :initform nil :accessor first-responder)
   (hover-view :initform nil :accessor hover-view)
   (capture-view :initform nil :accessor capture-view)
   (capture-origin :initform '(0 0) :accessor capture-origin)
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
         (content (make-instance 'view :background (if (member :background initargs) background (theme-color :paper))
                                       :frame (if borderless
                                                  (vector 0 0 (window-width window) (window-height window))
                                                  (destructuring-bind (left top right bottom) (coerce (content-insets window) 'list)
                                                    (vector left top (- (window-width window) left right)
                                                            (- (window-height window) top bottom)))))))
    (setf (view-window frame) window
          (frame-view window) frame
          (content-view window) content)
    (add-subview frame content)
    window))

(defun set-window-title (window title)
  (setf (window-title window) title)
  (when (typep (frame-view window) 'theme-frame)
    (setf (title (frame-view window)) title)
    (needs-display (frame-view window)))
  (sync-window-metadata window))

(defun set-window-location (window location)
  (setf (window-location window) location) (sync-window-metadata window))

(defun sync-window-metadata (window)
  (when (window-id window)
    (layer:window-metadata (window-id window) (window-title window) (window-location window)
                           :private (window-private window) :transient (window-transient window) :question (window-question window))))

(defun commit (window)
  (display (frame-view window))
  (layer:commit (window-context window)))

(bsd:define-process-variable *run-set* nil)

(defun listen-to (window)
  (when *run-set*
    (mach:mach-port-move-member mach:*task* (layer:context-events (window-context window)) *run-set*)))

(bsd:define-process-variable *menus* nil)

(defun terminate (&optional sender)
  (declare (ignore sender))
  (bsd:exit 0))

(defun front-window ()
  (or (find-if (lambda (w) (and (eq (style w) :titled) (frame-active (frame-view w)))) (windows))
      (find :titled (windows) :key #'style)))

(defun close-front-window (&optional sender)
  (declare (ignore sender)) (let ((window (front-window))) (when window (close-window window))))

(defun minimize-front-window (&optional sender)
  (declare (ignore sender)) (let ((window (front-window)))
    (when window (minimize-window window))))

(defun system-menu ()
  (list :system
        (cons "Set Up darterfly…" (lambda (sender) (declare (ignore sender))
                                    (bsd:posix-spawn "/System/Applications/Setup.app/Contents/Programs/Setup" '("Setup") nil)))
        (cons "Generations…" (lambda (sender) (declare (ignore sender))
                               (bsd:posix-spawn "/System/Applications/Generations.app/Contents/Programs/Generations" '("Generations") nil)))
        :separator
        (cons "Save System" (lambda (sender) (declare (ignore sender)) (darterfly/power:save-system)))
        :separator
        (cons "Restart" (lambda (sender) (declare (ignore sender)) (darterfly/power:save-system :then :restart)))
        (cons "Shut Down" (lambda (sender) (declare (ignore sender)) (darterfly/power:save-system :then :shut-down)))))

(defun standard-menus (name &rest menus)
  (let ((menus (copy-tree (or menus
                            (list (list "File" (cons "Close Window" #'close-front-window))
                                  (list "Edit" (cons "Copy" nil) (cons "Paste" nil)))))))
    (flet ((include-item (heading label action)
             (let ((menu (assoc heading menus :test #'equal)))
               (unless menu
                 (setf menu (list heading) menus (append menus (list menu))))
               (unless (find label (cdr menu) :test #'equal :key (lambda (item) (and (consp item) (car item))))
                 (setf (cdr menu) (append (cdr menu) (list (cons label action))))))))
      (include-item "Window" "Switch to a window…" (lambda (sender) (declare (ignore sender)) (invoke-command :switch-window)))
      (include-item "Window" "Minimize" (lambda (sender) (declare (ignore sender)) (invoke-command :minimize)))
      (include-item "Help" "Run a command…" (lambda (sender) (declare (ignore sender)) (read-command))))
    (cons (list name (cons (format nil "About ~a" name) nil) :separator
                (cons (format nil "Quit ~a" name) #'terminate)) menus)))

(defvar *menu-mark* nil)
(defun menu-heading-font (index) (ui-font 12 (if (= index 1) :bold :semibold)))
(defun menu-heading-width (title index)
  (if (eq title :system) 19 (ceiling (text:string-width (menu-heading-font index) title))))

(defparameter +menu-font-size+ 12)
(defparameter +item-height+ 26)

(defclass menu-bar-view (view)
  ((menus :initarg :menus :reader menus)
   (positions :accessor positions)
   (open-index :initform nil :accessor menu-open-index)
   (tracking :initform nil :accessor menu-tracking)
   (dropdown :initform nil :accessor dropdown)))

(defun menu-heading-at (view x y)
  (when (<= 0 y 25)
    (loop for (title) in (menus view) for left in (positions view) for index from 0
          when (<= (- left 9) x (+ left (menu-heading-width title index) 11)) return index)))

(defmethod draw ((view menu-bar-view) bitmap)
  (loop for (title) in (menus view) for x in (positions view) for index from 0
        do (when (eql index (menu-open-index view))
             (apply #'text:fill-rect bitmap (- x 9) 0 (+ 20 (menu-heading-width title index)) 26
                    (coerce (theme-color :paper) 'list)))
           (if (eq title :system)
               (let ((pixels (or *menu-mark* (setf *menu-mark* (imageio:icon "/System/Library/Startup/tied-darter-menu.png" 19)))))
                 (draw-rgba bitmap pixels 19 19 x 3))
               (text:draw-string bitmap (menu-heading-font index) title x 17 .16 .17 .19))))

(defclass menu-view (view)
  ((items :initarg :items :reader items)
   (bar :initarg :bar :reader bar)
   (selected :initform nil :accessor menu-selected)
   (pressed :initform nil :accessor menu-pressed)))

(defun menu-item-height (item) (if (eq item :separator) 9 +item-height+))
(defun menu-height (items) (+ 10 (reduce #'+ items :key #'menu-item-height :initial-value 0)))

(defmethod draw ((view menu-view) bitmap)
  (let ((font (ui-font 12)) (w (view-width view)) (h (view-height view)))
    ;; Attached to the bar: straight open top, quiet sides, rounded lower corners.
    (apply #'text:fill-round-rect bitmap 0 0 w h 7 (coerce (rgb8 183 177 168) 'list))
    (apply #'text:fill-rect bitmap 0 0 w 7 (coerce (rgb8 183 177 168) 'list))
    (apply #'text:fill-round-rect bitmap 1 0 (- w 2) (- h 1) 6 (coerce (theme-color :paper) 'list))
    (apply #'text:fill-rect bitmap 1 0 (- w 2) 7 (coerce (theme-color :paper) 'list))
    (loop for item in (items view) for index from 0
          for y = 5 then (+ y (menu-item-height previous))
          for previous = item
          do (if (eq item :separator)
                 (text:fill-rect bitmap 12 (+ y 4) (- w 24) 1 0.82 0.79 0.75)
                 (let ((ink (theme-color (if (cdr item) :ink :disabled-ink))))
                   (when (eql (menu-selected view) index)
                     (apply #'text:fill-round-rect bitmap 4 y (- w 8) +item-height+ 4
                            (coerce (theme-color :selection) 'list)))
                   (text:draw-string bitmap font (car item) 16 (+ y 17)
                                     (aref ink 0) (aref ink 1) (aref ink 2)))))))

(defgeneric popup-dismissed (view) (:method ((view view)) nil))

(defmethod popup-dismissed ((view menu-view))
  (setf (dropdown (bar view)) nil (menu-open-index (bar view)) nil)
  (needs-display (bar view)))

(defun close-dropdown (bar)
  (let ((window (shiftf (dropdown bar) nil)))
    (setf (menu-open-index bar) nil)
    (needs-display bar)
    (when window (close-window window))))

(defun menu-row-at (view x y)
  (when (<= 4 x (- (view-width view) 5))
    (loop for item in (items view) for index from 0
          for top = 5 then (+ top (menu-item-height previous))
          for previous = item
          when (and (<= top y) (< y (+ top (menu-item-height item))))
            return (and (consp item) (cdr item) index))))

(defmethod mouse-moved ((view menu-view) x y)
  (let ((index (menu-row-at view x y)))
    (unless (eql index (menu-selected view)) (setf (menu-selected view) index) (needs-display view))))
(defmethod mouse-exited ((view menu-view))
  (setf (menu-selected view) nil) (needs-display view))
(defmethod mouse-down ((view menu-view) x y)
  (setf (menu-pressed view) t) (mouse-moved view x y) t)
(defun choose-menu-row (view index)
  (when index
    (let ((action (cdr (nth index (items view)))))
      (close-dropdown (bar view)) (funcall action view))))
(defmethod mouse-up ((view menu-view) x y)
  (when (shiftf (menu-pressed view) nil)
    (let ((index (menu-row-at view x y)))
      (if index (choose-menu-row view index) (close-dropdown (bar view))))))
(defmethod key-down ((view menu-view) characters keycode)
  (declare (ignore characters))
  (let ((enabled (loop for item in (items view) for index from 0
                       when (and (consp item) (cdr item)) collect index)))
    (case keycode
      (1 (close-dropdown (bar view)))
      ((105 106)
       (open-dropdown (bar view) (mod (+ (menu-open-index (bar view)) (if (= keycode 105) -1 1))
                                       (length (menus (bar view)))) t))
      ((103 108)
       (when enabled
         (let ((at (position (menu-selected view) enabled)))
           (setf (menu-selected view)
                 (nth (if at (mod (+ at (if (= keycode 103) -1 1)) (length enabled))
                          (if (= keycode 103) (1- (length enabled)) 0)) enabled))
           (needs-display view))))
      ((28 57) (when (member (menu-selected view) enabled) (choose-menu-row view (menu-selected view)))))))

(defun open-dropdown (view index &optional keyboard)
  (close-dropdown view)
  (let* ((items (cdr (nth index (menus view))))
         (font (ui-font 12))
         (width (max 210 (+ 42 (ceiling (reduce #'max items
                                   :key (lambda (i) (if (consp i) (text:string-width font (car i)) 0)) :initial-value 0)))))
         (bounds (layer:main-display-bounds))
         (window (make-window :style :borderless :level :pop-up-menu
                              :x (max 2 (min (- (third bounds) width 2) (- (nth index (positions view)) 9))) :y 26
                              :width width :height (menu-height items) :background nil))
         (menu (make-instance 'menu-view :items items :bar view :frame (vector 0 0 width (menu-height items)))))
    (when keyboard
      (setf (menu-selected menu) (position-if (lambda (i) (and (consp i) (cdr i))) items)))
    (add-subview (content-view window) menu)
    (setf (first-responder window) menu (dropdown view) window (menu-open-index view) index)
    (needs-display view)
    (show window)))

(defmethod mouse-down ((view menu-bar-view) x y)
  (let ((index (menu-heading-at view x y)))
    (setf (menu-tracking view) t)
    (if (or (null index) (eql index (menu-open-index view)))
        (close-dropdown view)
        (open-dropdown view index)))
  t)

(defmethod mouse-moved ((view menu-bar-view) x y)
  (when (dropdown view)
    (let ((index (menu-heading-at view x y)))
      (cond ((and index (not (eql index (menu-open-index view)))) (open-dropdown view index))
            ((and (menu-tracking view) (>= y 26))
             (let ((window (dropdown view)))
               (mouse-moved (first-responder window) (- x (window-x window)) (- y 26))))))))

(defmethod mouse-up ((view menu-bar-view) x y)
  (when (and (shiftf (menu-tracking view) nil) (dropdown view) (>= y 26))
    (let* ((window (dropdown view)) (menu (first-responder window)))
      (let ((index (menu-row-at menu (- x (window-x window)) (- y 26))))
        (if index (choose-menu-row menu index) (close-dropdown view))))))

(defun menu-bar (menus)
  (let* ((menus (cons (system-menu) menus))
         (positions (loop with x = 20 for (title) in menus for index from 0
                          collect (prog1 x (incf x (+ 22 (menu-heading-width title index))))))
         (width (+ (car (last positions)) 12 (menu-heading-width (caar (last menus)) (1- (length menus)))))
         (window (make-window :style :borderless :level :main-menu :x 0 :y 0 :width width :height 26 :background nil))
         (view (make-instance 'menu-bar-view :menus menus :frame (vector 0 0 width 26))))
    (setf (positions view) positions)
    (add-subview (content-view window) view)
    (show window)
    window))

(defun show (window)
  (unless (app-menu *application*)
    (setf (app-menu *application*) t)
    (setf (app-menu *application*)
          (menu-bar (or *menus* (standard-menus (bsd:proc-comm bsd:*proc*))))))
  (unless (window-context window)
    (setf (window-context window) (layer:context-create))
    (setf (layer:context-layer (window-context window)) (view-layer (frame-view window))))
  (commit window)
  (unless (window-id window)
    (setf (window-id window)
          (layer:window-create (window-context window) (window-x window) (window-y window)
                            (window-width window) (window-height window) :level (window-level window)
                            :min-width (min-width window) :min-height (min-height window))))
  (sync-window-metadata window)
  (unless (member window (app-windows *application*))
    (push window (app-windows *application*))
    (listen-to window))
  window)

(defun close-window (window)
  (when (window-id window)
    (layer:transaction-commit (list (list :order (window-id window) :out))))
  (setf (app-windows *application*) (remove window (app-windows *application*)))
  (when (capture-view window) (cancel-pointer (capture-view window)))
  (setf (capture-view window) nil (hover-view window) nil)
  (when (window-context window) (layer:context-destroy (window-context window)))
  (setf (window-context window) nil (window-id window) nil))

(defun any-dirty (view)
  (or (dirty view) (some #'any-dirty (subviews view))))

(defun set-key-focus (window view &optional keyboard)
  (let ((previous (first-responder window)))
    (when previous (cancel-key previous) (setf (focused-p previous) nil) (focus-changed previous))
    (setf (first-responder window) view)
    (when view (setf (focused-p view) (and keyboard (focusable-p view))) (focus-changed view))))

(defun focusable-views (view)
  (append (when (focusable-p view) (list view)) (mapcan #'focusable-views (subviews view))))

(defun cycle-focus (window)
  (let* ((views (focusable-views (content-view window)))
         (at (position (first-responder window) views))
         (backward (member :shift *key-modifiers*)))
    (when views
      (set-key-focus window (nth (if at (mod (+ at (if backward -1 1)) (length views))
                                   (if backward (1- (length views)) 0)) views) t)
      t)))

(defun window-mouse-down (window x y)
  (let ((frame (frame-view window)))
    (if (and (eq (style window) :titled) (< y +title-height+))
        (setf (chrome-pressed frame) (chrome-control-at x y))
        (let ((hit (view-at (content-view window) x y)))
          (when hit
            (destructuring-bind (view lx ly) hit
              (set-key-focus window view)
              (setf (capture-view window) view (capture-origin window) (list (- x lx) (- y ly)))
              (mouse-down view lx ly)))))
    (needs-display frame)))

(defun window-mouse-moved (window x y)
  (let* ((frame (frame-view window))
         (hit (view-at (content-view window) x y))
         (view (if (capture-view window) (capture-view window) (first hit))))
    (when (typep frame 'theme-frame)
      (let ((control (chrome-control-at x y)))
        (unless (eq control (chrome-hover frame)) (setf (chrome-hover frame) control) (needs-display frame))))
    (unless (eq view (hover-view window))
      (when (hover-view window) (mouse-exited (hover-view window)))
      (setf (hover-view window) view))
    (when view
      (if (capture-view window)
          (destructuring-bind (ox oy) (capture-origin window) (mouse-moved view (- x ox) (- y oy)))
          (mouse-moved view (second hit) (third hit))))))

(defun window-mouse-exited (window)
  (when (hover-view window) (mouse-exited (hover-view window)) (setf (hover-view window) nil))
  (when (typep (frame-view window) 'theme-frame)
    (setf (chrome-hover (frame-view window)) nil) (needs-display (frame-view window))))

(defun window-mouse-up (window x y)
  (let* ((frame (frame-view window))
         (control (and (typep frame 'theme-frame) (shiftf (chrome-pressed frame) nil)))
         (view (shiftf (capture-view window) nil)))
    (when view
      (destructuring-bind (ox oy) (capture-origin window) (mouse-up view (- x ox) (- y oy))))
    (when (and control (eq control (chrome-control-at x y)))
      (case control
        (:close (close-window window))
        (:minimize (minimize-window window))
        (:zoom (layer:transaction-commit (list (list :zoom (window-id window)))))))
    (needs-display frame)))

(defun window-active (window active)
  (let ((frame (frame-view window)))
    (when (typep frame 'theme-frame) (setf (frame-active frame) active) (needs-display frame))
    (when (first-responder window) (needs-display (first-responder window)))
    (unless active
      (when (first-responder window) (cancel-key (first-responder window)))
      (when (capture-view window) (cancel-pointer (capture-view window)) (setf (capture-view window) nil))
      (when (typep frame 'theme-frame) (setf (chrome-pressed frame) nil))
      (window-mouse-exited window))))

(defun window-frame-changed (window frame)
  (destructuring-bind (x y w h) frame
    (let ((resized (or (/= w (window-width window)) (/= h (window-height window)))))
      (setf (window-x window) x (window-y window) y)
      ;; The compositor moves existing surfaces. A move must not relayout or
      ;; rerasterize the app (nor invalidate focus and control state).
      (when resized
        (setf (window-width window) w (window-height window) h
              (view-frame (frame-view window)) (vector 0 0 w h))
        (if (eq (style window) :titled)
            (destructuring-bind (left top right bottom) (coerce (content-insets window) 'list)
              (resize-view (content-view window) (- w left right) (- h top bottom)))
            (resize-view (content-view window) w h))
        (needs-display (frame-view window))))))

(defun window-key-down (window characters keycode)
  (when *choice-panel*
    (let ((s (panel-session *choice-panel*)))
      (when (or (= keycode 1) (and (member :control *key-modifiers*) (= keycode 34)))
        (cancel-choice s) (return-from window-key-down nil)))
    (setf window (panel-window *choice-panel*)))
  (when (and (null *choice-panel*) (command-key window keycode *key-modifiers*))
    (return-from window-key-down t))
  (let* ((responder (or (first-responder window) (content-view window)))
         (target (keyboard-target responder)))
    ;; A popup exists locally before WindowServer has ordered its first frame.
    ;; Keys already queued to the parent still belong to that open popup.
    (unless (and (eq target responder) (string= characters (string #\Tab)) (cycle-focus window))
      (key-down target characters keycode))))

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

(defgeneric resumed (view)
  (:method ((view t)) nil))

(defmethod resumed ((view button)) (cancel-pointer view))
(defmethod resumed ((view theme-frame))
  (setf (chrome-hover view) nil (chrome-pressed view) nil))
(defmethod resumed ((view menu-bar-view))
  (setf (dropdown view) nil (menu-open-index view) nil (menu-tracking view) nil))

(defun resumable-window-p (window)
  ;; Application content survives a saved world. Menus are transient and their
  ;; old IPC/context ids must not be reopened as additional windows.
  (not (member (window-level window) '(:main-menu :pop-up-menu))))

(defun resume-view (view)
  (resumed view)
  (needs-display view)
  (mapc #'resume-view (subviews view)))

(defun resume ()
  (let ((windows (remove-if-not #'resumable-window-p (reverse (windows)))))
    (setf *choice-panel* nil *run-set* nil
          (app-main *application*) nil
          (app-menu *application*) nil
          (app-windows *application*) nil
          (slot-value *application* 'lock) (sb-thread:make-mutex :name "application"))
    (dolist (window windows)
      (setf (window-context window) nil (window-id window) nil
            (capture-view window) nil (hover-view window) nil (capture-origin window) nil)
      (resume-view (frame-view window))
      (show window))
    (run)))

(defun run ()
  (ensure-standard-commands)
  (setf bsd:*resume* #'resume)
  (let ((set (mach:mach-port-allocate mach:*task* :port-set)))
    (setf *run-set* set)
    (mach:mach-port-move-member mach:*task* (main-port) set)
    (dolist (window (windows))
      (mach:mach-port-move-member mach:*task* (layer:context-events (window-context window)) set))
    (loop
      (loop :for message := (mach:mach-msg-receive set) :then (handler-case (mach:mach-msg-receive set :timeout 0)
                                                                (mach:kern-return () nil))
            :while message
            :do (if (eql (mach:msgh-local-port message) (main-port))
                    (funcall (mach:msgh-body message))
                    (dispatch message)))
      (commit-dirty))))

(defun dispatch (message)
  (let ((window (find (mach:msgh-local-port message) (windows)
                      :key (lambda (w) (layer:context-events (window-context w)))))
        (event (mach:msgh-body message)))
    (when window
      (case (server:event-type event)
        ((:left-mouse-down :left-mouse-up :mouse-moved)
         (destructuring-bind (x y) (server:event-window-location event)
           (let ((*click-count* (or (server:event-value event :clicks) 1))
                 (*key-modifiers* (server:event-value event :modifiers)))
             (funcall (ecase (server:event-type event)
                        (:left-mouse-down #'window-mouse-down) (:left-mouse-up #'window-mouse-up)
                        (:mouse-moved #'window-mouse-moved)) window (round x) (round y)))))
        (:mouse-exited (window-mouse-exited window))
        (:application-open (open-application (content-view window)))
        (:window-activated (window-active window t))
        (:window-deactivated (window-active window nil))
        (:window-frame-changed (window-frame-changed window (server:event-value event :frame)))
        (:menu-dismissed
         (dolist (view (subviews (content-view window)))
           (popup-dismissed view))
         (close-window window))
        (:scroll-wheel
         (destructuring-bind (x y) (server:event-window-location event)
           (let ((hit (view-at (content-view window) (round x) (round y))))
             (scroll-wheel (if hit (first hit) (or (first-responder window) (content-view window)))
                           (server:event-value event :delta-x) (server:event-value event :delta-y)))))
        (:key-up
         (let ((*key-modifiers* (server:event-value event :modifiers)))
           (key-up (keyboard-target (or (first-responder window) (content-view window)))
                   (if (server:event-character event) (string (server:event-character event)) "")
                   (server:event-value event :keycode))))
        (:key-down
         (let ((char (server:event-character event)) (*key-modifiers* (server:event-value event :modifiers)))
           (when char (window-key-down window (string char) (server:event-value event :keycode))))))
      window)))

(defun forget-icons ()
  (setf *icons-lock* (sb-thread:make-mutex :name "icons")))

(pushnew 'forget-icons sb-ext:*save-hooks*)
