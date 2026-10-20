(in-package #:darterfly/apps)

(defun disk-description (disk)
  (format nil "~,1f GB NVMe disk" (/ (darterfly/devices:get-property disk "Size") 1d9)))

(defclass install-page (journey-page)
  ((welcome :initform nil :accessor welcome-p)
   (mark :initform nil :accessor welcome-mark)))

(defmethod kit:draw ((page install-page) bitmap)
  (kit:fill-surface bitmap)
  (let ((w (kit:view-width page)) (h (kit:view-height page)))
    (when (welcome-p page)
      (apply #'text:fill-rect bitmap 0 0 150 (- h 48) (coerce (kit:theme-color :sidebar) 'list))
      (text:fill-rect bitmap 149 0 1 (- h 48) .78 .76 .73)
      (text:fill-ellipse bitmap 75 103 34 34 .173 .239 .302)
      (let ((pixels (or (welcome-mark page)
                        (setf (welcome-mark page) (darterfly/imageio:icon "/System/Library/Startup/tied-darter.png" 56)))))
        (kit:draw-rgba bitmap pixels 56 56 47 75)))
    (apply #'text:fill-rect bitmap 0 (- h 48) w 48 (coerce (kit:theme-color :surface) 'list))
    (text:fill-rect bitmap 0 (- h 48) w 1 .79 .77 .73)))

(defmethod kit:resize-view ((page install-page) width height)
  (let ((dx (- width (kit:view-width page))) (dy (- height (kit:view-height page))))
    (dolist (view (kit:subviews page))
      (when (and (typep view 'journey-caption) (>= (aref (kit:view-frame view) 1) (- (kit:view-height page) 48)))
        (incf (aref (kit:view-frame view) 1) dy))
      (when (typep view 'journey-button)
        (incf (aref (kit:view-frame view) 0) dx))))
  (call-next-method))

(defun install-welcome (page)
  (kit:remove-subviews page)
  (setf (welcome-p page) t (journey-buttons page) nil (journey-focus page) 0 (journey-default page) #'kit:terminate)
  (let ((window (kit::window-of page))) (when window (kit:set-window-title window "Welcome")))
  (flet ((label (string x y size &optional bold)
           (let ((view (make-instance 'journey-caption :page page :string string :font-size size
                                      :font-name (if bold "Nunito-Bold" "Nunito-Regular")
                                      :text-color (kit:theme-color (if bold :ink :muted))
                                      :frame (vector x y (if (< x 150) 120 410) (+ size 8)))))
             (kit:add-subview page view))))
    (label "darterfly" 46 151 13 t)
    (label "Welcome to darterfly" 178 30 18 t)
    (label "The desktop is yours to explore." 178 62 12)
    (label "Open your apps, try a few ideas, or give darterfly a home" 178 94 12)
    (label "on this computer." 178 112 12)
    (label "You're running from USB. Save work to another drive to keep it." 178 144 11)
    (label "Live session" 16 (- (kit:view-height page) 29) 10))
  (let ((y 248) (w (kit:view-width page)))
    (journey-button page "Install…" (lambda () (install-confirm page)) (- w 192) y :width 70)
    (let ((button (journey-button page "Try darterfly" #'kit:terminate (- w 114) y :width 98 :role :primary)))
      (setf (journey-focus page) 1)
      (let ((window (kit::window-of page))) (when window (kit::set-key-focus window button t)))))
  (kit:needs-display page))

(defun install-footer-button (page label action x &rest options)
  (apply #'journey-button page label action (+ x (- (kit:view-width page) 610)) 248 options))

(defun install-confirm (page)
  (setf (welcome-p page) nil)
  (let ((window (kit::window-of page))) (when window (kit:set-window-title window "Install darterfly")))
  (kit:needs-display page)
  (let ((disk (darterfly/install:internal-disk)))
    (if (null disk)
        (progn
          (journey-layout page "INSTALLATION" "No supported disk found"
                          '("The installer currently supports internal NVMe disks."
                            "You can keep trying darterfly without installing it.")
                          :escape (lambda () (install-welcome page)))
          (install-footer-button page "Back" (lambda () (install-welcome page)) 388 :width 70))
        (progn
          (journey-layout page "INSTALLATION   /   CONFIRM DISK" "Erase this disk and install?"
                          (list (format nil "Destination: ~a" (disk-description disk))
                                "Everything on this disk will be erased."
                                "Copy any files you want to keep before continuing."
                                "After installation, we'll help you set up your desktop.")
                          :escape (lambda () (install-welcome page)))
          (install-footer-button page "Back" (lambda () (install-welcome page)) 388 :width 70)
          (install-footer-button page "Erase and Install" (lambda () (install-run page disk)) 466 :width 128 :role :danger)))))

(defun install-run (page disk)
  (journey-layout page "INSTALLATION" "Installing darterfly"
                  '("Preparing the installation. Keep this computer powered on."))
  (bsd:bsdthread-create
   (lambda ()
     (handler-case
         (progn
           (darterfly/install:install-disk
            :disk disk :progress
            (lambda (step)
              (kit:perform-on-main
               (lambda ()
                 (journey-layout page "INSTALLATION" "Installing darterfly"
                                 (list step "Keep this computer powered on until installation finishes."))))))
           (kit:perform-on-main
            (lambda ()
              (journey-layout page "INSTALLATION COMPLETE" "Ready for your first start"
                              '("1. Shut down this computer."
                                "2. Remove the installation USB drive."
                                "3. Turn it on to set up your new desktop."))
              (install-footer-button page "Keep Exploring" #'kit:terminate 346 :width 130)
              (install-footer-button page "Shut Down" #'darterfly/power:shut-down 484 :width 110))))
       (error (e)
         (ignore-errors
           (with-open-file (s "/tmp/Install-error.txt" :direction :output :if-exists :supersede)
             (princ e s)))
         (kit:perform-on-main
          (lambda ()
            (journey-layout page "INSTALLATION" "Installation couldn't finish"
                            '("The destination disk may contain an incomplete installation."
                              "Keep the installation USB drive connected."
                              "Details are saved in /tmp/Install-error.txt."))
            (install-footer-button page "Back" (lambda () (install-welcome page)) 388 :width 70))))))
   "install"))

(bsd:define-program "Install" (argv envp)
  (setf kit:*menus* (kit:standard-menus "Install"))
  (multiple-value-bind (width height) (screen-size)
    (let* ((window (kit:make-window :title "Welcome" :width 610 :height 310 :min-width 610 :min-height 310
                                    :x (floor (- width 610) 2) :y (max 26 (floor (- height 310) 2))
                                    :content-insets #(0 26 0 0)))
           (page (make-instance 'install-page :base-height 284 :frame #(0 0 610 284))))
      (kit:add-subview (kit:content-view window) page)
      (install-welcome page)
      (kit:show window)
      (kit:run))))
