(defpackage #:darterfly/health
  (:use #:cl)
  (:export #:check #:*checks*))
(in-package #:darterfly/health)

(defvar *checks* nil)

(defmacro define-check (name &body body)
  `(progn
     (setf *checks* (append (remove ',name *checks* :key #'first) (list (list ',name (lambda () ,@body)))))
     ',name))

(defun alive-thread-p (name)
  (and (find name (sb-thread:list-all-threads) :key #'sb-thread:thread-name :test #'equal) t))

(define-check :log
  (if (and darterfly/log::*logger* (sb-thread:thread-alive-p darterfly/log::*logger*))
      (list :ok)
      (list :fail :logger :stopped)))

(define-check :errors
  (let ((errors darterfly/bsd:*background-errors*))
    (list :ok :count (length errors)
              :latest (and errors (list (getf (first errors) :thread) (getf (first errors) :error))))))

(define-check :network
  (let ((i darterfly/net:*interface*))
    (cond ((or (null i) (null (darterfly/net::interface-device i))) (list :absent))
          ((zerop (darterfly/net::interface-ip i)) (list :fail :ip :none))
          ((zerop (darterfly/net::interface-gateway i)) (list :fail :gateway :none))
          (t (let* ((gateway (darterfly/net:address-string (darterfly/net::interface-gateway i)))
                    (rtt (ignore-errors (darterfly/net:ping gateway))))
               (list (if rtt :ok :fail) :ip (darterfly/net:address-string (darterfly/net::interface-ip i))
                     :gateway gateway :ms (and rtt (round (* rtt 1000)))))))))

(define-check :wifi
  (if (null darterfly/wifi::*card*)
      (list :absent)
      (let ((status (darterfly/wifi:network-status)))
        (list (if (and (eq (getf status :kind) :wifi) (getf status :up)) :ok :fail)
              :ssid (getf status :ssid) :signal (getf status :signal)
              :rejoining (and darterfly/wifi::*link* (darterfly/wifi::wireless-rejoining darterfly/wifi::*card*))))))

(define-check :display
  (if (null (darterfly/display::graphics))
      (list :absent)
      (let ((on (darterfly/display::panel-on-p))
            (plane (darterfly/display:awake (darterfly/display::plane-state))))
        (list (if (and on (getf plane :enabled) (not darterfly/display::*psr-unreliable*)) :ok :fail)
              :panel on :plane (getf plane :enabled)
              :psr darterfly/display::*psr* :psr-unreliable darterfly/display::*psr-unreliable*
              :psr-failures (length darterfly/display::*psr-failures*)
              :dc darterfly/display::*dc-target*))))

(define-check :touchpad
  (if (null (darterfly/devices:find-entries 'darterfly/devices::intel-lpss-i2c-controller))
      (list :absent)
      (let ((pads (darterfly/devices:find-entries 'darterfly/devices::i2c-hid-device)))
        (list (if pads :ok :fail) :devices (length pads)))))

(define-check :disk
  (let ((disk (find-if (lambda (m) (darterfly/devices:get-property m "Whole"))
                       (darterfly/devices:find-entries 'darterfly/devices:media))))
    (if (null disk)
        (list :absent)
        (let ((block (darterfly/devices:media-read disk 0 512)))
          (list (if (= (length block) 512) :ok :fail)
                :name (darterfly/devices:get-property disk "BSD Name")
                :nvme (typep (darterfly/devices:media-device disk) 'darterfly/devices::nvme-disk))))))

(define-check :battery
  (let ((battery (darterfly/devices:battery)))
    (if (null battery)
        (list :absent)
        (list* (if (getf battery :percent) :ok :fail) battery))))

(define-check :audio
  (let ((devices (darterfly/audio:audio-devices)))
    (if (null devices)
        (list :absent)
        (let ((codecs (loop for d in devices append (darterfly/devices:get-property d "Codecs"))))
          (list (if codecs :ok :fail) :codecs codecs)))))

(define-check :usb
  (let ((controllers (darterfly/devices:find-entries 'darterfly/devices::xhci-controller)))
    (if (null controllers)
        (list :absent)
        (list :ok :controllers (length controllers)
                  :hid (mapcar #'darterfly/devices:entry-name (darterfly/devices:find-entries 'darterfly/devices::usb-hid-device))))))

(define-check :watchdog
  (if (alive-thread-p "heartbeat") (list :ok) (list :absent)))

(defun check ()
  (loop for (name thunk) in *checks*
        collect (cons name (handler-case (funcall thunk)
                             (error (e) (list :fail :error (princ-to-string e)))))))
