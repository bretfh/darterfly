(in-package #:darterfly/apps)

(defparameter *desktop-preferences-path* "/Users/darterfly/Library/Preferences/desktop.sexp")
(defparameter *setup-pending-path* "/Library/Settings/setup-pending")
(defparameter *desktop-colors*
  '((:ocean "Ocean" #(0.18 0.36 0.56 1.0))
    (:forest "Forest" #(0.20 0.35 0.29 1.0))
    (:slate "Slate" #(0.28 0.29 0.33 1.0))))

(defun default-desktop-preferences ()
  (list :version 1 :color :ocean :clock-24 nil :page 0 :complete nil))

(defvar *desktop-preferences* (default-desktop-preferences))

(defun valid-desktop-preferences-p (value)
  (and (listp value) (ignore-errors
    (and (= (length value) 10)
         (every (lambda (key) (= 1 (count key value)))
                '(:version :color :clock-24 :page :complete))
         (eql (getf value :version) 1)
         (assoc (getf value :color) *desktop-colors*)
         (member (getf value :clock-24) '(nil t))
         (typep (getf value :page) '(integer 0 2))
         (member (getf value :complete) '(nil t))))))

(defun read-desktop-preferences ()
  (or (ignore-errors
        (with-open-file (s *desktop-preferences-path*)
          (with-standard-io-syntax
            (let* ((*read-eval* nil) (value (read s nil nil)))
              (and (valid-desktop-preferences-p value) value)))))
      (default-desktop-preferences)))

(defun save-desktop-preferences (value)
  (unless (valid-desktop-preferences-p value) (error "Invalid desktop preferences"))
  (let ((temporary (concatenate 'string *desktop-preferences-path* ".new")))
    (ensure-directories-exist temporary)
    (with-open-file (s temporary :direction :output :if-exists :supersede)
      (with-standard-io-syntax (prin1 value s) (terpri s)))
    (uiop:rename-file-overwriting-target temporary *desktop-preferences-path*)
    (when (sb-sys:find-foreign-symbol-address "__machdep5")
      (darterfly/power:flush-disks))
    (setf *desktop-preferences* (copy-list value))))

(defun setup-needed-p ()
  (and (probe-file *setup-pending-path*) (not (getf *desktop-preferences* :complete))))

(defun desktop-color ()
  (third (assoc (getf *desktop-preferences* :color) *desktop-colors*)))

(defun launch-app (name)
  (let ((path (format nil "/System/Applications/~a.app/Contents/Programs/~a" name name)))
    (bsd:posix-spawn path (list name) nil)))

;; The same layout and keyboard behavior serve live welcome, installation and setup.
(defclass journey-page (kit:view)
  ((buttons :initform nil :accessor journey-buttons)
   (focus :initform 0 :accessor journey-focus)
   (default :initform nil :accessor journey-default)))

(defclass journey-button (kit:button)
  ((page :initarg :page :reader journey-page)
   (selected :initarg :selected :initform nil :reader journey-selected)))

(defclass journey-caption (kit:text-field)
  ((page :initarg :page :reader journey-page)))

(defmethod kit:key-down ((caption journey-caption) characters keycode)
  (kit:key-down (journey-page caption) characters keycode))

(defmethod kit:draw ((button journey-button) bitmap)
  (call-next-method)
  (let ((page (journey-page button)))
    (when (or (journey-selected button)
              (eq button (nth (journey-focus page) (journey-buttons page))))
      (text:fill-rect bitmap 5 (- (kit:view-height button) 4) (- (kit:view-width button) 10) 2 0.15 0.42 0.78))))

(defmethod kit:key-down ((button journey-button) characters keycode)
  (kit:key-down (journey-page button) characters keycode))

(defmethod kit:mouse-down ((button journey-button) x y)
  (setf (journey-focus (journey-page button))
        (position button (journey-buttons (journey-page button))))
  (call-next-method))

(defmethod kit:key-down ((page journey-page) characters keycode)
  (declare (ignore keycode))
  (let ((char (and (plusp (length characters)) (char characters 0)))
        (buttons (journey-buttons page)))
    (cond ((and (eql char #\Tab) buttons)
           (setf (journey-focus page) (mod (1+ (journey-focus page)) (length buttons)))
           (mapc #'kit:needs-display buttons))
          ((and (member char '(#\Return #\Newline #\Space)) buttons)
           (let ((button (nth (journey-focus page) buttons)))
             (funcall (kit:action button) button)))
          ((and (eql char #\Escape) (journey-default page))
           (funcall (journey-default page)))))
  t)

(defun journey-label (page string x y &optional (size 15) (color #(0.25 0.27 0.31)))
  (kit:add-subview page (make-instance 'journey-caption :page page :string string :font-size size :text-color color
                                      :frame (vector x y 520 (+ size 8)))))

(defun journey-button (page title action x y &key (width 160) selected)
  (let ((button (make-instance 'journey-button :page page :selected selected :title title
                               :frame (vector x y width 34)
                               :action (lambda (sender) (declare (ignore sender)) (funcall action)))))
    (setf (journey-buttons page) (append (journey-buttons page) (list button)))
    (kit:add-subview page button)))

(defun journey-layout (page stage title lines &key escape)
  (kit:remove-subviews page)
  (setf (journey-buttons page) nil (journey-focus page) 0 (journey-default page) escape)
  (journey-label page stage 24 16 12 #(0.15 0.42 0.78))
  (journey-label page title 24 42 26 #(0.10 0.13 0.18))
  (loop for line in lines for y from 88 by 24 do (journey-label page line 24 y))
  (let ((window (kit::window-of page)))
    (when window (setf (kit:first-responder window) page))))

(defun journey-window (title)
  (multiple-value-bind (width height) (screen-size)
    (let* ((window (kit:make-window :title title :x (max 0 (floor (- width 600) 2))
                                    :y (max 28 (floor (- height 380) 2)) :width 600 :height 380))
           (page (make-instance 'journey-page :frame #(0 0 576 328))))
      (kit:add-subview (kit:content-view window) page)
      (setf (kit:first-responder window) page)
      (values window page))))

(defun setup-network-line ()
  (let ((status (ignore-errors (darterfly/wifi:network-status))))
    (cond ((not (getf status :up)) "Network: offline. You can finish setup without it.")
          ((eq (getf status :kind) :wired) "Network: wired connection detected.")
          (t "Network: Wi-Fi connection detected."))))

(defun setup-page (page preferences &optional message)
  (let ((step (getf preferences :page)))
    (labels ((change (key value)
               (let ((next (copy-list preferences)))
                 (setf (getf next key) value)
                 (handler-case
                     (progn (save-desktop-preferences next) (setup-page page next))
                   (error () (setup-page page preferences "Could not save. Check the disk and try again.")))))
             (finish ()
               (let ((next (copy-list preferences)))
                 (setf (getf next :complete) t)
                 (handler-case
                     (progn (save-desktop-preferences next) (kit:terminate))
                   (error () (setup-page page preferences "Could not save. Check the disk and try again."))))))
      (journey-layout page (format nil "MAKE YOURSELF AT HOME   /   ~d OF 3" (1+ step))
                      (nth step '("Welcome to darterfly" "Make the clock yours" "You're ready to explore"))
                      (case step
                        (0 '("Choose a desktop color. You can change it later."
                             "Your choices are saved as you go."))
                        (1 '("Choose how the menu bar displays the time."
                             "This changes the format, not the time zone."))
                        (2 (list (setup-network-line)
                                 "Files opens your disk. Double-click folders to explore."
                                 "The Dock opens Terminal, Listener, and Generations."
                                 "Return to this assistant from the Files menu.")))
                      :escape #'kit:terminate)
      (case step
        (0 (loop for (key name nil) in *desktop-colors* for x from 24 by 174
                 do (let ((color key))
                      (journey-button page name (lambda () (change :color color)) x 156
                                      :selected (eq color (getf preferences :color))))))
        (1 (journey-button page "12-hour  /  2:30 PM" (lambda () (change :clock-24 nil)) 24 156 :width 246
                           :selected (not (getf preferences :clock-24)))
           (journey-button page "24-hour  /  14:30" (lambda () (change :clock-24 t)) 294 156 :width 246
                           :selected (getf preferences :clock-24))))
      (when message (journey-label page message 24 207 13 #(0.75 0.15 0.12)))
      (journey-button page "Set Up Later" #'kit:terminate 24 246)
      (when (plusp step) (journey-button page "Back" (lambda () (change :page (1- step))) 198 246))
      (journey-button page (if (= step 2) "Start Using darterfly" "Continue")
                      (if (= step 2) #'finish (lambda () (change :page (1+ step)))) 372 246 :width 168)
      (setf (journey-focus page) (1- (length (journey-buttons page))))
      (journey-label page "Tab to move between buttons. Enter to choose. Esc to leave." 24 295 11))))

(bsd:define-program "Setup" (argv envp)
  (setf kit:*menus* (kit:standard-menus "Setup"))
  (multiple-value-bind (window page) (journey-window "Set Up darterfly")
    (let ((preferences (read-desktop-preferences)))
      (when (getf preferences :complete) (setf (getf preferences :page) 0))
      (setup-page page preferences))
    (kit:show window)
    (kit:run)))
