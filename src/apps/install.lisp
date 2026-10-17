(in-package #:darterfly/apps)

(defun disk-description (disk)
  (format nil "~,1f GB NVMe disk" (/ (darterfly/devices:get-property disk "Size") 1d9)))

(defun install-page (content lines buttons)
  (kit:remove-subviews content)
  (loop for line in lines for y from 24 by 26
        do (kit:add-subview content (make-instance 'kit:text-field :string line :font-size 15 :frame (vector 24 y 470 24))))
  (loop for (title action) in buttons for x from 24 by 170
        do (kit:add-subview content (make-instance 'kit:button :title title :frame (vector x 130 156 32)
                                                               :action (lambda (button) (declare (ignore button)) (funcall action)))))
  (kit:needs-display content))

(defun install-welcome (content)
  (install-page content
                '("Try this system as it is, or install it" "on this computer's disk.")
                (list (list "Try" #'kit:terminate)
                      (list "Install..." (lambda () (install-confirm content))))))

(defun install-confirm (content)
  (let ((disk (darterfly/install:internal-disk)))
    (if (null disk)
        (install-page content '("No internal disk was found.") (list (list "Back" (lambda () (install-welcome content)))))
        (install-page content
                      (list "Install erases everything on the" (format nil "~a and puts this system on it." (disk-description disk)))
                      (list (list "Back" (lambda () (install-welcome content)))
                            (list "Erase and Install" (lambda () (install-run content))))))))

(defun install-run (content)
  (install-page content '("Installing...") nil)
  (bsd:bsdthread-create
   (lambda ()
     (flet ((show (lines &optional buttons)
              (kit:perform-on-main (lambda () (install-page content lines buttons)))))
       (handler-case
           (progn
             (darterfly/install:install-disk :progress (lambda (step) (show (list "Installing..." step))))
             (show '("Installed." "Remove the USB stick and restart.") (list (list "Done" #'kit:terminate))))
         (error (e)
           (show (list "The install failed:" (princ-to-string e)) (list (list "Back" (lambda () (install-welcome content)))))))))
   "install"))

(bsd:define-program "Install" (argv envp)
  (setf kit:*menus* (kit:standard-menus "Install"))
  (let* ((screen (handler-case (third (layer:main-display-bounds)) (error () 1280)))
         (window (kit:make-window :title "Install" :x (floor (- screen 540) 2) :y 50 :width 540 :height 230)))
    (install-welcome (kit:content-view window))
    (kit:show window)
    (kit:run)))
