(in-package #:darterfly/apps)

(defun disk-description (disk)
  (format nil "~,1f GB NVMe disk" (/ (darterfly/devices:get-property disk "Size") 1d9)))

(defun install-welcome (page)
  (journey-layout page "LIVE SESSION" "Welcome to darterfly"
                  '("Explore the desktop, or install darterfly on this computer."
                    "Trying it does not install the system on your internal disk."
                    "Files and settings in this live session are temporary.")
                  :escape #'kit:terminate)
  (journey-button page "Try darterfly" #'kit:terminate 24 246 :width 246)
  (journey-button page "Install darterfly..." (lambda () (install-confirm page)) 294 246 :width 246)
  (journey-label page "You can return using Install darterfly on the desktop." 24 203 13))

(defun install-confirm (page)
  (let ((disk (darterfly/install:internal-disk)))
    (if (null disk)
        (progn
          (journey-layout page "INSTALLATION" "No supported disk found"
                          '("The installer currently supports internal NVMe disks."
                            "You can keep trying darterfly without installing it.")
                          :escape (lambda () (install-welcome page)))
          (journey-button page "Back" (lambda () (install-welcome page)) 24 246))
        (progn
          (journey-layout page "INSTALLATION   /   CONFIRM DISK" "Erase this disk and install?"
                          (list (format nil "Destination: ~a" (disk-description disk))
                                "Everything on this disk will be erased."
                                "Copy any files you want to keep before continuing."
                                "After installation, we'll help you set up your desktop.")
                          :escape (lambda () (install-welcome page)))
          (journey-button page "Back" (lambda () (install-welcome page)) 24 246)
          (journey-button page "Erase and Install" (lambda () (install-run page disk)) 372 246 :width 168)))))

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
              (journey-button page "Keep Exploring" #'kit:terminate 24 246 :width 246)
              (journey-button page "Shut Down" #'darterfly/power:shut-down 294 246 :width 246))))
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
            (journey-button page "Back" (lambda () (install-welcome page)) 24 246))))))
   "install"))

(bsd:define-program "Install" (argv envp)
  (setf kit:*menus* (kit:standard-menus "Install"))
  (multiple-value-bind (window page) (journey-window "Install darterfly")
    (install-welcome page)
    (kit:show window)
    (kit:run)))
