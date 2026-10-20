(in-package #:darterfly/windowserver)

;; This is compositor work, after console-off, not an animation claimed to run
;; inside UEFI. The captured pixels and exact cursor survive that ownership change.
(defstruct startup snapshot origin glyphs mark badge name started (ready nil))

(defun startup-ease (value)
  (let ((v (max 0.0 (min 1.0 (float value))))) (* v v (- 3.0 (* 2.0 v)))))

(defun startup-time (state)
  (/ (- (get-internal-real-time) (startup-started state)) (float internal-time-units-per-second)))

(defun make-startup-glyphs ()
  (let ((font (with-open-file (s "/System/Library/Startup/console-font.bin" :element-type '(unsigned-byte 8))
                (let ((bytes (make-array 2048 :element-type '(unsigned-byte 8)))) (read-sequence bytes s) bytes)))
        (glyphs (make-hash-table)))
    (loop for ch across ".'_/\\|o=" do
      (let ((pixels (make-array (* 8 16 4) :element-type '(unsigned-byte 8) :initial-element 0)))
        (dotimes (y 16)
          (dotimes (x 8)
            (when (logbitp (- 7 x) (aref font (+ (* (char-code ch) 16) y)))
              (let ((at (* 4 (+ x (* y 8)))))
                (setf (aref pixels at) 216 (aref pixels (+ at 1)) 216
                      (aref pixels (+ at 2)) 208 (aref pixels (+ at 3)) 255)))))
        (setf (gethash ch glyphs) pixels)))
    glyphs))

(defun begin-startup ()
  (unless (or (darterfly/devices:boot-arg "safe")
              (equal (darterfly/devices:boot-arg "boot-animation") "off"))
    (handler-case
        (let* ((snapshot (io:capture-framebuffer *framebuffer*))
               (origin (darterfly/devices:boot-console-position))
               (scale (max 1 (third origin)))
               (badge (darterfly/text:make-bitmap (* 88 scale) (* 88 scale)))
               (name (darterfly/text:make-bitmap (* 160 scale) (* 28 scale)))
               (font (darterfly/text:font "Nunito-SemiBold" (* 18 scale))))
          (darterfly/text:fill-ellipse badge (* 44 scale) (* 44 scale) (* 44 scale) (* 44 scale) .149 .208 .255)
          (darterfly/text:draw-string name font "darterfly"
            (round (- (* 160 scale) (darterfly/text:string-width font "darterfly")) 2)
            (* 21 scale) .941 .953 .969)
          (setf *startup* (make-startup :snapshot snapshot :origin origin :glyphs (make-startup-glyphs)
                           :mark (darterfly/imageio:icon "/System/Library/Startup/tied-darter.png" (* 128 scale))
                           :badge (darterfly/text:bitmap-pixels badge) :name (darterfly/text:bitmap-pixels name)
                           :started (get-internal-real-time)))
          (format t "Startup: retained console, origin ~s~%" origin))
      (error (e) (setf *startup* nil) (format t "Startup: direct desktop fallback: ~a~%" e)))))

(defun finish-startup (reason)
  (when *startup*
    (format t "Startup: ~a after ~,3fs; desktop-ready=~s~%" reason (startup-time *startup*) (startup-ready *startup*))
    (setf *startup* nil)
    (damage-all)))

(defun startup-desktop-ready-p ()
  ;; Every shell surface must have committed content, not merely created a window.
  (every (lambda (level)
           (some (lambda (w)
                   (let ((client (and (ordered w) (context-client (window-context w)))))
                     (and (= level (window-level w)) client (root client)))) *windows*))
         '(-2147483623 20 23 24)))

(defun mix-startup-snapshot (fb snapshot blue arrival)
  (declare (optimize (speed 3)) (type single-float blue arrival))
  (let ((out (io:framebuffer-pixels fb)) (a (round (* 256 arrival))) (b (round (* 256 blue))))
    (declare (type (simple-array (unsigned-byte 32) (*)) out snapshot) (type fixnum a b))
    (dotimes (i (length out))
      (let ((old (aref snapshot i)) (desktop (aref out i)) (pixel #xff000000))
        (declare (type (unsigned-byte 32) old desktop pixel))
        (dotimes (c 3)
          (let* ((shift (* 8 c)) (source (ldb (byte 8 shift) old))
                 (base (ash (+ (* (- 256 b) source) (* b (case c (0 143) (1 92) (2 46)))) -8))
                 (value (ash (+ (* (- 256 a) base) (* a (ldb (byte 8 shift) desktop))) -8)))
            (setf pixel (logior pixel (ash value shift)))))
        (setf (aref out i) pixel)))))

(defparameter +startup-ascii+
  '("   ..                "
    "   .\\\\.              "
    "    .\\\\.             "
    "  .\\..\\\\.ooo         "
    "   .\\\\\\.\\oooo===     "
    "      .\\\\\\\\.=======  "
    "     /////\\\\..  ..   "
    "    ////   .\\\\.      "
    "    //  /    .       "
    "     ////            "))

(defun draw-startup (fb)
  (let* ((s *startup*) (elapsed (startup-time s))
         (scale (max 1 (third (startup-origin s))))
         (w (io:framebuffer-width fb)) (h (io:framebuffer-height fb)) (clip (list 0 0 w h))
         (cx (/ w 2)) (cy (- (/ h 2) (* 66 scale)))
         (reduced (darterfly/devices:boot-arg "reduced-motion"))
         (flight (startup-ease (/ (- elapsed .65) .75)))
         (reveal (startup-ease (/ (- elapsed .83) .50)))
         (arrival (if (startup-ready s) (startup-ease (/ (- elapsed (max (startup-ready s) (if reduced .05 1.45))) .30)) 0.0))
         (opacity (- 1.0 arrival)))
    (when (and (null (startup-ready s)) (startup-desktop-ready-p))
      (setf (startup-ready s) elapsed)
      (format t "Startup: complete shell frame at ~,3fs~%" elapsed))
    (when (or (>= arrival 1.0) (> elapsed 4.0))
      (finish-startup (if (> elapsed 4.0) :timeout :complete))
      (return-from draw-startup nil))
    (mix-startup-snapshot fb (startup-snapshot s) (if reduced 1.0 (startup-ease (/ (- elapsed .55) .8))) arrival)
    (labels ((blit (pixels x y dw dh iw ih alpha &optional (region clip))
               (io:blit-image fb (round x) (round y) (round dw) (round dh) pixels iw ih (float (* opacity alpha)) region)))
      (unless reduced
        (destructuring-bind (ox oy unused) (startup-origin s)
          (declare (ignore unused))
          (let* ((tx (min (- w (* 180 scale)) (max (* 90 scale) (+ ox (* 84 scale)))))
                 (ty (min (- h (* 100 scale)) (max (* 90 scale) (+ oy (* 70 scale)))))
                 (x (+ tx (* (- cx tx) flight))) (y (+ ty (* (- cy ty) flight)))
                 (unit (* scale (- 1.0 (* .62 flight))))
                 (edge (+ (- x (* 84 unit)) (* 168 unit reveal)))
                 (index 0))
            (loop for line in +startup-ascii+ for gy from 0 do
              (loop for ch across line for gx from 0 unless (char= ch #\Space) do
                (let* ((p (max 0.0 (min 1.0 (/ (- elapsed (* index .0035)) .32))))
                       (e (startup-ease p))
                       (symbol (cond ((< p .32) (if (zerop (mod index 4)) #\_ #\.))
                                     ((< p .55) #\.) ((< p .8) (char "/\\|_" (mod index 4))) (t ch)))
                       (px (+ ox (* (- (+ x (* (- gx 10.5) 8 unit)) ox) e)
                              (* (sin (* pi p)) (* 18 scale))))
                       (py (+ oy (* (- (+ y (* (- gy 5) 16 unit)) oy) e)
                              (* (sin (+ (* elapsed 20) gx)) (- 1.0 flight) 2 scale))))
                  (blit (gethash symbol (startup-glyphs s)) px py (* 8 unit) (* 16 unit) 8 16
                        (min 1.0 (* p 8)) (list (round edge) 0 w h)))
                (incf index)))
            (blit (startup-mark s) (- x (* 32 scale)) (- y (* 32 scale)) (* 64 scale) (* 64 scale)
                  (* 128 scale) (* 128 scale) 1.0 (list 0 0 (round edge) h)))))
      (let ((settle (if reduced 1.0 (startup-ease (/ (- elapsed 1.22) .23)))))
        (blit (startup-badge s) (- cx (* 44 scale)) (- cy (* 44 scale)) (* 88 scale) (* 88 scale)
              (* 88 scale) (* 88 scale) settle)
        (blit (startup-mark s) (- cx (* 32 scale)) (- cy (* 32 scale)) (* 64 scale) (* 64 scale)
              (* 128 scale) (* 128 scale) settle)
        (blit (startup-name s) (- cx (* 80 scale)) (+ cy (* 46 scale)) (* 160 scale) (* 28 scale)
              (* 160 scale) (* 28 scale) settle))
      ;; Activity only while real shell surfaces are absent. No fabricated percent.
      (when (and (> elapsed 1.4) (not (startup-desktop-ready-p)))
        (dotimes (i 8)
          (let ((angle (* 2 pi (/ i 8))) (a (* opacity (+ .2 (* .8 (/ (mod (+ i (floor (* elapsed 10))) 8) 7))))))
            (io:blend-rect fb (round (+ cx (* 7 scale (cos angle)))) (round (+ cy (* 92 scale) (* 7 scale (sin angle))))
                           (round (+ cx (* 7 scale (cos angle)) (* 2 scale))) (round (+ cy (* 92 scale) (* 7 scale (sin angle)) (* 2 scale)))
                           .94 .95 .97 (float a))))))))

(defun startup-loop ()
  (loop while *startup* do
    (sleep (/ 1.0 60))
    (sb-thread:with-mutex (*lock*)
      (when *startup*
        (handler-case (progn (damage-all) (render))
          (error (e) (format t "Startup: fallback: ~a~%" e) (finish-startup :error) (render)))))))
