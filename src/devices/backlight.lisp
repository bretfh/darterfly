(in-package #:darterfly/devices)

(defparameter *brightness-setting* "/Library/Settings/brightness")
(defconstant +pwm-period+ #xc8254)
(defconstant +pwm-duty+ #xc8258)

(defvar *backlight* :unknown)

(pushnew 'forget-backlight sb-ext:*save-hooks*)

(defun forget-backlight ()
  (setf *backlight* :unknown))

(defun backlight ()
  (when (eq *backlight* :unknown)
    (setf *backlight*
          (ignore-errors
           (let ((gpu (find-if (lambda (d) (and (= (config-read-16 d 0) #x8086) (= (config-read-8 d #xb) 3)))
                               (find-entries 'pci-node))))
             (and gpu (map-virtual-address (map-device-memory-with-index gpu 0)))))))
  *backlight*)

(defun brightness ()
  (let ((base (backlight)))
    (when base
      (let ((period (mmio-read (+ base +pwm-period+) 32)))
        (and (plusp period) (/ (mmio-read (+ base +pwm-duty+) 32) period))))))

(defun set-brightness (fraction &key (save t))
  (let ((base (backlight)))
    (when base
      (let ((period (mmio-read (+ base +pwm-period+) 32)))
        (when (plusp period)
          (mmio-write (+ base +pwm-duty+) 32 (round (* period (max 0.05 (min 1 fraction)))))
          (when save
            (ignore-errors
             (ensure-directories-exist *brightness-setting*)
             (with-open-file (s *brightness-setting* :direction :output :if-exists :supersede)
               (prin1 (float fraction 1.0) s))))
          fraction)))))

(defun restore-brightness ()
  (let ((saved (ignore-errors (with-open-file (s *brightness-setting*) (read s)))))
    (when (realp saved)
      (set-brightness saved :save nil))))
