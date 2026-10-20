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
    (open-application path)))

;; The same layout and keyboard behavior serve live welcome, installation and setup.
(defclass journey-page (kit:view)
  ((base-height :initarg :base-height :initform 328 :reader journey-base-height)
   (buttons :initform nil :accessor journey-buttons)
   (focus :initform 0 :accessor journey-focus)
   (default :initform nil :accessor journey-default)))

(defmethod kit:resize-view ((page journey-page) width height)
  (let ((dy (- height (kit:view-height page))))
    (dolist (button (journey-buttons page))
      (when (journey-bottom-anchored button) (incf (aref (kit:view-frame button) 1) dy))))
  (call-next-method))

(defclass journey-button (kit:button)
  ((page :initarg :page :reader journey-page)
   (selected :initarg :selected :initform nil :reader journey-selected)
   (bottom-anchored :initarg :bottom-anchored :initform nil :reader journey-bottom-anchored)))

(defclass journey-caption (kit:text-field)
  ((page :initarg :page :reader journey-page)))

(defmethod kit:key-down ((caption journey-caption) characters keycode)
  (kit:key-down (journey-page caption) characters keycode))

(defmethod kit:focus-changed ((button journey-button))
  (when (kit:focused-p button)
    (setf (journey-focus (journey-page button)) (position button (journey-buttons (journey-page button)))))
  (call-next-method))

(defmethod kit:draw ((button journey-button) bitmap)
  (call-next-method)
  (when (journey-selected button)
    (text:fill-ellipse bitmap 14 17 2 2 0.396 0.373 0.341)))

(defmethod kit:key-down ((button journey-button) characters keycode)
  ;; Keep page Escape behavior; command presses use the shared release/cancel
  ;; contract rather than the old assistant's immediate activation shortcut.
  (if (and (plusp (length characters)) (eql (char characters 0) #\Escape))
      (if (kit::button-armed button) (call-next-method)
          (kit:key-down (journey-page button) characters keycode))
      (call-next-method)))

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
           (loop for button in buttons for i from 0 do
             (setf (kit:focused-p button) (= i (journey-focus page))) (kit:needs-display button)))
          ((and (member char '(#\Return #\Newline #\Space)) buttons)
           (let ((button (nth (journey-focus page) buttons)))
             (kit:activate button)))
          ((and (eql char #\Escape) (journey-default page))
           (funcall (journey-default page)))))
  t)

(defun journey-label (page string x y &optional (size 13) (color #(0.396 0.373 0.341)))
  (kit:add-subview page (make-instance 'journey-caption :page page :string string :font-size size :text-color color
                                      :frame (vector x y 520 (+ size 8)))))

(defun journey-button (page title action x y &key (width 160) selected (role :secondary))
  (let ((button (make-instance 'journey-button :page page :selected selected :title title :role role :bottom-anchored (>= y 246)
                               :frame (vector x (+ y (if (>= y 246) (max 0 (- (kit:view-height page) (journey-base-height page))) 0)) width 26)
                               :action (lambda (sender) (declare (ignore sender)) (funcall action)))))
    (setf (journey-buttons page) (append (journey-buttons page) (list button)))
    (kit:add-subview page button)
    (when (= 1 (length (journey-buttons page)))
      (setf (kit:focused-p button) t)
      (let ((window (kit::window-of page)))
        (when window (kit::set-key-focus window button t))))
    button))

(defun journey-layout (page stage title lines &key escape)
  (kit:remove-subviews page)
  (setf (journey-buttons page) nil (journey-focus page) 0 (journey-default page) escape)
  (journey-label page stage 24 16 11 #(0.396 0.373 0.341))
  (journey-label page title 24 42 20 #(0.208 0.208 0.208))
  (loop for line in lines for y from 88 by 24 do (journey-label page line 24 y))
  (let ((window (kit::window-of page)))
    (when window (setf (kit:first-responder window) page))))

(defun journey-window (title)
  (multiple-value-bind (width height) (screen-size)
    (let* ((window (kit:make-window :title title :x (max 0 (floor (- width 600) 2))
                                    :y (max 28 (floor (- height 380) 2)) :width 600 :height 380 :min-width 600 :min-height 380))
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
    (labels ((change (key value &optional source)
               (let ((next (copy-list preferences))
                     (kind (and source (class-of source)))
                     (keyboard (and source (kit:focused-p source))))
                 (setf (getf next key) value)
                 (handler-case
                     (progn (save-desktop-preferences next) (setup-page page next))
                   (error () (setup-page page preferences "Could not save. Check the disk and try again.")))
                 ;; A preference edit stays on its control. Only navigation
                 ;; moves focus to the next page's default command.
                 (when kind
                   (let ((replacement (find kind (kit:subviews page) :key #'class-of))
                         (window (kit::window-of page)))
                     (when (and replacement window) (kit::set-key-focus window replacement keyboard))))))
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
        (0 (kit:add-subview page
             (make-instance 'kit:popup-button :frame #(24 156 246 26) :value (getf preferences :color)
               :choices (loop for (key name nil) in *desktop-colors*
                              collect (list :label name :value key))
               :action (lambda (control) (change :color (kit:selected-value control) control)))))
        (1 (kit:add-subview page
             (make-instance 'kit:checkbox :frame #(24 156 360 26) :title "Use a 24-hour clock"
               :checked (getf preferences :clock-24)
               :action (lambda (control) (change :clock-24 (kit:checked-p control) control))))))
      (when message (journey-label page message 24 207 13 #(0.75 0.15 0.12)))
      (journey-button page "Set Up Later" #'kit:terminate 24 246)
      (when (plusp step) (journey-button page "Back" (lambda () (change :page (1- step))) 198 246))
      (journey-button page (if (= step 2) "Start Using darterfly" "Continue")
                      (if (= step 2) #'finish (lambda () (change :page (1+ step)))) 372 246 :width 168 :role :primary)
      (setf (journey-focus page) (1- (length (journey-buttons page))))
      (loop for button in (journey-buttons page) for i from 0 do
        (setf (kit:focused-p button) (= i (journey-focus page))) (kit:needs-display button))
      (let ((window (kit::window-of page)))
        (when window (kit::set-key-focus window (car (last (journey-buttons page))) t)))
      (journey-label page "Tab between controls. Space to choose. Esc to leave." 24 295 11))))

(bsd:define-program "Setup" (argv envp)
  (setf kit:*menus* (kit:standard-menus "Setup"))
  (multiple-value-bind (window page) (journey-window "Set Up darterfly")
    (let ((preferences (read-desktop-preferences)))
      (when (getf preferences :complete) (setf (getf preferences :page) 0))
      (setup-page page preferences))
    (kit:show window)
    (kit:run)))
