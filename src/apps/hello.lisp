(defpackage #:finch/apps
  (:use #:cl)
  (:local-nicknames (#:ca #:finch/ca) (#:bsd #:finch/bsd)))
(in-package #:finch/apps)

(defun window (x y width height title-color content-color)
  (let* ((title (ca:make-layer :background-color title-color))
         (content (ca:make-layer :background-color content-color))
         (window (ca:make-layer :background-color #(0.93 0.93 0.93 1.0) :masks-to-bounds t
                                :sublayers (list title content))))
    (setf (ca:layer-frame window) (vector x y width height)
          (ca:layer-frame title) (vector 0 0 width 28)
          (ca:layer-frame content) (vector 12 40 (- width 24) (- height 52)))
    window))

(bsd:define-program "Hello" (argv envp)
  (let ((context (ca:context-create)))
    (setf (ca:context-layer context)
          (window 212 134 600 400 #(0.85 0.85 0.85 1.0) #(1.0 1.0 1.0 1.0)))
    (ca:commit context)
    (loop (bsd:pause))))
