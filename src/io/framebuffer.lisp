(defpackage #:finch/io
  (:use #:cl)
  (:export #:framebuffer #:open-framebuffer #:framebuffer-width #:framebuffer-height
           #:framebuffer-pixels #:flush #:fill-rect #:test-pattern
           #:read-events #:wait-for-events #:open-hid #:hid-event #:event-type #:event-code #:event-value #:blend-rect
           #:input-devices #:kextload #:load-kexts #:*kexts* #:modules-dir #:abs-range #:event-fd #:blit-image #:key-character #:shift-key-p #:virtual-keycode #:shadow-under #:save-corners #:restore-corners #:*clip*))
(in-package #:finch/io)

(defclass framebuffer ()
  ((width :initarg :width :reader framebuffer-width)
   (height :initarg :height :reader framebuffer-height)
   (depth :initarg :depth :reader depth)
   (stride :initarg :stride :reader stride)
   (sap :initarg :sap :reader sap)
   (pixels :initarg :pixels :reader framebuffer-pixels)))

(defun sysfs (name)
  (string-trim '(#\Newline #\Space)
               (uiop:read-file-string (format nil "/sys/class/graphics/fb0/~a" name))))

(defconstant +kdsetmode+ #x4b3a)
(defconstant +kd-graphics+ 1)

(defun graphics-mode ()
  (ignore-errors
   (let ((fd (sb-posix:open "/dev/tty0" sb-posix:o-rdwr)))
     (sb-posix:ioctl fd +kdsetmode+ +kd-graphics+)
     fd)))

(defun open-boot-framebuffer ()
  (destructuring-bind (&key row-bytes width height depth base) (finch/iokit:boot-video)
    (make-instance 'framebuffer :width width :height height :depth depth :stride row-bytes
                                :sap (sb-sys:int-sap (finch/iokit:ml-io-map-wcomb base (* row-bytes height)))
                                :pixels (make-array (* width height) :element-type '(unsigned-byte 32)
                                                                     :initial-element #xff000000))))

(defun open-framebuffer (&optional (device "/dev/fb0"))
  (unless (probe-file device)
    (return-from open-framebuffer (open-boot-framebuffer)))
  (graphics-mode)
  (destructuring-bind (width height)
      (mapcar #'parse-integer (uiop:split-string (sysfs "virtual_size") :separator ","))
    (let* ((depth (parse-integer (sysfs "bits_per_pixel")))
           (stride (parse-integer (sysfs "stride")))
           (fd (sb-posix:open device sb-posix:o-rdwr))
           (sap (sb-posix:mmap nil (* stride height) (logior sb-posix:prot-read sb-posix:prot-write)
                               sb-posix:map-shared fd 0)))
      (make-instance 'framebuffer :width width :height height :depth depth :stride stride :sap sap
                                  :pixels (make-array (* width height) :element-type '(unsigned-byte 32)
                                                                       :initial-element #xff000000)))))

(defun flush (fb &key (x 0) (y 0) (width (framebuffer-width fb)) (height (framebuffer-height fb)))
  (declare (optimize (speed 3) (safety 0)))
  (let ((pixels (framebuffer-pixels fb))
        (sap (sap fb))
        (stride (stride fb))
        (w (framebuffer-width fb))
        (x0 (max 0 x)) (y0 (max 0 y)))
    (declare (type (simple-array (unsigned-byte 32) (*)) pixels)
             (type fixnum stride w x0 y0))
    (let ((x1 (min w (+ x0 width)))
          (y1 (min (framebuffer-height fb) (+ y0 height))))
      (declare (type fixnum x1 y1))
      (ecase (depth fb)
        (32 (loop :for row fixnum :from y0 :below y1
                  :do (loop :for col fixnum :from x0 :below x1
                            :do (setf (sb-sys:sap-ref-32 sap (+ (* row stride) (* col 4)))
                                      (aref pixels (+ (* row w) col))))))
        (24 (loop :for row fixnum :from y0 :below y1
                  :do (loop :for col fixnum :from x0 :below x1
                            :for p :of-type (unsigned-byte 32) := (aref pixels (+ (* row w) col))
                            :for at :of-type fixnum := (+ (* row stride) (* col 3))
                            :do (setf (sb-sys:sap-ref-8 sap at) (ldb (byte 8 0) p)
                                      (sb-sys:sap-ref-8 sap (+ at 1)) (ldb (byte 8 8) p)
                                      (sb-sys:sap-ref-8 sap (+ at 2)) (ldb (byte 8 16) p)))))))
    fb))

(defun fill-rect (fb x y width height argb)
  (declare (optimize (speed 3)) (type fixnum x y width height) (type (unsigned-byte 32) argb))
  (let ((pixels (framebuffer-pixels fb))
        (w (framebuffer-width fb)))
    (declare (type (simple-array (unsigned-byte 32) (*)) pixels) (type fixnum w))
    (loop :for row fixnum :from (max 0 y) :below (min (framebuffer-height fb) (+ y height))
          :do (fill pixels argb :start (+ (* row w) (max 0 x)) :end (+ (* row w) (min w (+ x width)))))
    fb))

(defun test-pattern (fb)
  (let ((w (framebuffer-width fb)) (h (framebuffer-height fb)))
    (fill-rect fb 0 0 w h #xff202020)
    (fill-rect fb 0 0 (floor w 2) (floor h 2) #xffff0000)
    (fill-rect fb (floor w 2) 0 (floor w 2) (floor h 2) #xff00ff00)
    (fill-rect fb 0 (floor h 2) (floor w 2) (floor h 2) #xff0000ff)
    (flush fb)))
