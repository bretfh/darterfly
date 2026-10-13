(defpackage #:finch/apps
  (:use #:cl)
  (:local-nicknames (#:ca #:finch/ca) (#:bsd #:finch/bsd) (#:text #:finch/text) (#:kit #:finch/kit)))
(in-package #:finch/apps)

(defun label (string font r g b)
  (let* ((width (ceiling (+ 2 (text:string-width font string))))
         (height (ceiling (+ (text:font-ascent font) (text:font-descent font))))
         (bitmap (text:make-bitmap width height)))
    (text:draw-string bitmap font string 1 (text:font-ascent font) r g b)
    (let ((layer (ca:make-layer :contents (ca:image width height (text:bitmap-pixels bitmap)))))
      (setf (ca:layer-frame layer) (vector 0 0 width height))
      layer)))

(defun place (layer x y)
  (let ((frame (ca:layer-frame layer)))
    (setf (ca:layer-frame layer) (vector x y (aref frame 2) (aref frame 3)))
    layer))

(defun window (x y width height title-color content-color &optional (title "") (body nil))
  (let* ((title-label (label title (text:font "SFNS" 13) 0.2 0.2 0.2))
         (title (ca:make-layer :background-color title-color
                               :sublayers (list (place title-label
                                                       (floor (- width (aref (ca:layer-frame title-label) 2)) 2)
                                                       6))))
         (content (ca:make-layer :background-color content-color
                                 :sublayers (and body (list (place body 20 20)))))
         (window (ca:make-layer :background-color #(0.93 0.93 0.93 1.0) :masks-to-bounds t
                                :sublayers (list title content))))
    (setf (ca:layer-frame window) (vector x y width height)
          (ca:layer-frame title) (vector 0 0 width 28)
          (ca:layer-frame content) (vector 12 40 (- width 24) (- height 52)))
    window))

(bsd:define-program "Hello" (argv envp)
  (let* ((window (kit:make-window :title "Hello" :x 212 :y 134 :width 600 :height 400))
         (label (make-instance 'kit:text-field :string "Hello from finch." :font-size 28
                                               :frame (vector 20 20 400 40)))
         (button (make-instance 'kit:button :title "Click me" :frame (vector 20 80 120 32)
                                            :action (lambda (button)
                                                      (declare (ignore button))
                                                      (setf (kit:string-value label) "You clicked.")))))
    (kit:add-subview (kit:content-view window) label)
    (kit:add-subview (kit:content-view window) button)
    (kit:show window)
    (kit:run)))
