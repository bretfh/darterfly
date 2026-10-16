(in-package #:finch/apps)

(defparameter *fetch-logo*
  '("              .---.         "
    "             /  o  \\___     "
    "            |       ___>    "
    "       .----'      (         "
    "     .'   .--.      \\        "
    "    /    / ~~ \\      |       "
    "   |    | ~~~~ |     |       "
    "    \\    \\ ~~ /     /        "
    "     `-.  `--'   .-'\\        "
    "        `--.__.-'  `--.__   "
    "           ||          `-  "
    "          _||_              "))

(defun fetch-cpu ()
  (flet ((leaf (n)
           (with-output-to-string (s)
             (dolist (word (multiple-value-list (sb-vm::%cpu-identification n 0)))
               (dotimes (i 4) (let ((c (ldb (byte 8 (* 8 i)) word))) (unless (zerop c) (write-char (code-char c) s))))))))
    (string-trim " " (format nil "~{~a~}" (mapcar #'leaf '(#x80000002 #x80000003 #x80000004))))))

(defun fetch-uptime ()
  (let ((s (floor (get-internal-real-time) internal-time-units-per-second)))
    (multiple-value-bind (m s) (floor s 60)
      (multiple-value-bind (h m) (floor m 60)
        (format nil "~@[~d h ~]~d min ~d s" (and (plusp h) h) m s)))))

(defun fetch-devices ()
  (let ((found nil))
    (flet ((have (class label) (when (finch/devices:find-entries class) (push label found))))
      (have 'finch/devices::nvme-disk "NVMe")
      (have 'finch/devices::xhci-controller "xHCI")
      (have 'finch/devices::usb-cdc-ecm "USB Ethernet")
      (have 'finch/devices::i2c-hid-device "I2C touchpad")
      (have 'finch/devices::usb-hid-device "USB HID")
      (have 'finch/devices:virtio-network "virtio")
      (when (finch/devices:battery) (push "EC battery" found)))
    (format nil "~{~a~^, ~}" (reverse found))))

(defun fetch-facts ()
  (flet ((try (thunk) (handler-case (funcall thunk) (error () "?"))))
    `(("OS" "finch 0.1 x86_64")
      ("Kernel" "Mach + BSD, in Lisp")
      ("Uptime" ,(try #'fetch-uptime))
      ("Lisp" ,(format nil "~a ~a" (lisp-implementation-type) (lisp-implementation-version)))
      ("CPU" ,(try #'fetch-cpu))
      ("Memory" ,(try (lambda () (format nil "~d / ~d MB heap" (floor (sb-kernel:dynamic-usage) 1048576)
                                         (floor (sb-ext:dynamic-space-size) 1048576)))))
      ("Display" ,(try (lambda () (destructuring-bind (x y w h) (layer:main-display-bounds)
                                    (declare (ignore x y)) (format nil "~dx~d, UEFI GOP" w h)))))
      ("Network" ,(try (lambda () (let ((i finch/net:*interface*))
                                    (if i (format nil "en0 ~a" (finch/net:address-string (finch/net::interface-ip i))) "down")))))
      ("Battery" ,(try (lambda () (let ((b (finch/devices:battery)))
                                    (if b (format nil "~d%~:[~;, charging~]" (getf b :percent) (getf b :charging)) "none")))))
      ("Devices" ,(try #'fetch-devices))
      ("Kit" ,(try (lambda () (labels ((walk (e) (1+ (reduce #'+ (mapcar #'walk (finch/devices:entry-children e))))))
                                  (format nil "~d registry entries" (walk finch/devices:*registry-root*)))))))))

(defparameter *fetch-colors*
  '((0.80 0.36 0.30) (0.85 0.60 0.30) (0.86 0.76 0.42) (0.55 0.70 0.42)
    (0.42 0.66 0.66) (0.42 0.55 0.78) (0.66 0.50 0.74) (0.82 0.80 0.76)))

(defclass fetch-view (kit:view) ((facts :initarg :facts :reader facts)))

(defmethod kit:draw ((view fetch-view) bitmap)
  (text:fill-bitmap bitmap 0.10 0.11 0.12 1.0)
  (let* ((font (text:font "AdwaitaMono-Regular" 13))
         (line 18)
         (left 18)
         (right (+ left (ceiling (text:string-width font (make-string 30 :initial-element #\M)))))
         (top 30))
    (loop for row in *fetch-logo* for y from top by line for i from 0
          do (if (>= i 10)
                 (text:draw-string bitmap font row left y 0.62 0.58 0.52)
                 (text:draw-string bitmap font row left y 0.93 0.62 0.28)))
    (let ((y top))
      (text:draw-string bitmap font "bfh" right y 0.95 0.72 0.36)
      (text:draw-string bitmap font "@arraniz" (+ right (text:string-width font "bfh")) y 0.88 0.86 0.80)
      (incf y line)
      (text:draw-string bitmap font (make-string 11 :initial-element #\-) right y 0.40 0.42 0.44)
      (dolist (f (facts view))
        (incf y line)
        (let ((label (format nil "~a:" (first f))))
          (text:draw-string bitmap font label right y 0.95 0.72 0.36)
          (text:draw-string bitmap font (second f) (+ right (text:string-width font "Devices: ")) y 0.86 0.86 0.83)))
      (incf y (* 2 line))
      (loop for (r g b) in *fetch-colors* for x from right by 30
            do (text:fill-rect bitmap x (- y 13) 26 16 r g b)))))

(bsd:define-program "Fetch" (argv envp)
  (setf kit:*menus* (kit:standard-menus "Fetch"))
  (let* ((facts (fetch-facts))
         (screen (handler-case (third (layer:main-display-bounds)) (error () 1280)))
         (width 820) (height 330)
         (window (kit:make-window :title "Fetch" :x (- screen width 24) :y 60 :width width :height height))
         (view (make-instance 'fetch-view :facts facts :frame (vector 0 0 (- width 24) (- height 52)))))
    (kit:add-subview (kit:content-view window) view)
    (kit:show window)
    (kit:run)))

