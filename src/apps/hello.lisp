(defpackage #:finch/apps
  (:use #:cl)
  (:local-nicknames (#:ca #:finch/ca) (#:bsd #:finch/bsd) (#:text #:finch/text)))
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
  (let ((context (ca:context-create)))
    (setf (ca:context-layer context)
          (window 0 0 600 400 #(0.85 0.85 0.85 1.0) #(1.0 1.0 1.0 1.0) "Hello"
                  (label "Hello from finch." (text:font "SFNS" 28) 0.0 0.0 0.0)))
    (ca:commit context)
    (ca:window-create context 212 134 600 400)
    (loop (bsd:pause))))
