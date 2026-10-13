(defpackage #:finch/text
  (:use #:cl)
  (:export #:font #:font-size #:string-width #:draw-string #:bitmap #:make-bitmap
           #:bitmap-width #:bitmap-height #:bitmap-pixels #:fill-bitmap #:font-ascent #:font-descent))
(in-package #:finch/text)

(defparameter *fonts-dir* "/System/Library/Fonts/")
(defvar *loaders* (make-hash-table :test 'equal))
(defvar *lock* (sb-thread:make-mutex :name "fonts"))

(defmacro with-fonts (&body body)
  `(sb-thread:with-recursive-lock (*lock*) ,@body))

(defclass font ()
  ((loader :initarg :loader :reader loader)
   (size :initarg :size :reader font-size)))

(defun font (name size)
  (let ((loader (sb-thread:with-mutex (*lock*)
                  (or (gethash name *loaders*)
                      (setf (gethash name *loaders*)
                            (zpb-ttf:open-font-loader (format nil "~a~a.ttf" *fonts-dir* name)))))))
    (make-instance 'font :loader loader :size size)))

(defun scale (font)
  (/ (font-size font) (zpb-ttf:units/em (loader font))))

(defun font-ascent (font) (with-fonts (* (scale font) (zpb-ttf:ascender (loader font)))))
(defun font-descent (font) (with-fonts (* (scale font) (- (zpb-ttf:descender (loader font))))))

(defun glyphs (font string)
  (let ((loader (loader font)))
    (loop :for char :across string
          :collect (zpb-ttf:find-glyph char loader))))

(defun string-width (font string)
  (with-fonts (%string-width font string)))

(defun %string-width (font string)
  (let ((loader (loader font)))
    (* (scale font)
       (loop :for (glyph next) :on (glyphs font string)
             :sum (+ (zpb-ttf:advance-width glyph)
                     (if next (zpb-ttf:kerning-offset glyph next loader) 0))))))

(defstruct (bitmap (:constructor %make-bitmap (width height pixels))) width height pixels)

(defun make-bitmap (width height)
  (%make-bitmap width height (make-array (* width height 4) :element-type '(unsigned-byte 8) :initial-element 0)))

(defun fill-bitmap (bitmap r g b a)
  (let ((pixels (bitmap-pixels bitmap)))
    (loop :for i :from 0 :below (length pixels) :by 4
          :do (setf (aref pixels i) (round (* 255 r a))
                    (aref pixels (+ i 1)) (round (* 255 g a))
                    (aref pixels (+ i 2)) (round (* 255 b a))
                    (aref pixels (+ i 3)) (round (* 255 a))))
    bitmap))

(defun draw-string (bitmap font string x baseline r g b &optional (a 1.0))
  (with-fonts (%draw-string bitmap font string x baseline r g b a)))

(defun %draw-string (bitmap font string x baseline r g b a)
  (let ((state (net.tuxee.aa:make-state))
        (s (scale font))
        (loader (loader font))
        (pen x))
    (loop :for (glyph next) :on (glyphs font string)
          :do (dolist (path (net.tuxee.paths-ttf:paths-from-glyph
                             glyph :offset (net.tuxee.paths:make-point pen baseline)
                                   :scale-x s :scale-y (- s)))
                (net.tuxee.vectors:update-state state path))
              (incf pen (* s (+ (zpb-ttf:advance-width glyph)
                                (if next (zpb-ttf:kerning-offset glyph next loader) 0)))))
    (let ((pixels (bitmap-pixels bitmap))
          (w (bitmap-width bitmap))
          (h (bitmap-height bitmap)))
      (net.tuxee.aa:cells-sweep
       state
       (lambda (px py alpha)
         (when (and (< -1 px w) (< -1 py h))
           (let* ((cover (* a (/ (min 256 (abs alpha)) 256.0)))
                  (at (* 4 (+ px (* py w))))
                  (keep (- 1.0 cover)))
             (flet ((mix (i v)
                      (setf (aref pixels (+ at i))
                            (min 255 (round (+ (* 255 v cover) (* keep (aref pixels (+ at i)))))))))
               (mix 0 r) (mix 1 g) (mix 2 b) (mix 3 1.0)))))))
    pen))
