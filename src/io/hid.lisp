(in-package #:finch/io)

(defstruct (hid-event (:conc-name event-)) seconds type code value fd)

(defgeneric read-events (device))
(defgeneric abs-range (device axis))

(defmethod read-events ((in finch/iokit:apple-virtio-input))
  (loop for (type code value) in (finch/iokit:input-events in)
        collect (make-hid-event :seconds 0 :type type :code code :value value :fd in)))

(defmethod abs-range ((in finch/iokit:apple-virtio-input) axis) (finch/iokit:input-abs-range in axis))

(defgeneric event-vector (device))
(defmethod event-vector ((in finch/iokit:apple-virtio-input)) (finch/iokit:interrupt-vector in))

(defun wait-for-events (devices)
  (let ((vectors (mapcar #'event-vector devices)))
    (if (and vectors (every #'identity vectors))
        (finch/iokit:wait-for-interrupt vectors)
        (sleep 0.005))))

(defclass ps2-keyboard () ((extended :initform nil :accessor extended)))

(defparameter +extended-keys+
  '((#x1C . 96) (#x1D . 97) (#x35 . 98) (#x38 . 100) (#x47 . 102) (#x48 . 103) (#x49 . 104) (#x4B . 105)
    (#x4D . 106) (#x4F . 107) (#x50 . 108) (#x51 . 109) (#x52 . 110) (#x53 . 111) (#x5B . 125) (#x5C . 126)))

(defmethod read-events ((k ps2-keyboard))
  (let ((buffer (make-array 64 :element-type '(unsigned-byte 8))))
    (let ((n (sb-sys:with-pinned-objects (buffer)
               (finch/iokit::machdep 21 (sb-sys:sap-int (sb-sys:vector-sap buffer)) 64))))
      (loop :for i :below n
            :for code := (aref buffer i)
            :for key := (cond ((= code #xE0) (setf (extended k) t) nil)
                              ((extended k) (setf (extended k) nil) (cdr (assoc (logand code #x7F) +extended-keys+)))
                              (t (logand code #x7F)))
            :when key
              :collect (make-hid-event :seconds 0 :type 1 :code key :value (if (logtest code #x80) 0 1) :fd k)))))

(defmethod abs-range ((k ps2-keyboard) axis) (declare (ignore axis)) nil)
(defmethod event-vector ((k ps2-keyboard)) finch/iokit::+keyboard-vector+)

(defvar *ps2-keyboard* (make-instance 'ps2-keyboard))

(defparameter +usb-keys+
  #(0 0 0 0 30 48 46 32 18 33 34 35 23 36 37 38 50 49 24 25 16 19 31 20 22 47 17 45 21 44
    2 3 4 5 6 7 8 9 10 11 28 1 14 15 57 12 13 26 27 43 43 39 40 41 51 52 53 58
    59 60 61 62 63 64 65 66 67 68 87 88 99 70 119 110 102 104 111 107 109 106 105 108 103
    69 98 55 74 78 96 79 80 81 75 76 77 71 72 73 82 83 86 127))

(defparameter +usb-modifiers+ #(29 42 56 125 97 54 100 126))

(defun key-event (device code down)
  (make-hid-event :seconds 0 :type 1 :code code :value (if down 1 0) :fd device))

(defun keyboard-report (device report)
  (let ((last (finch/iokit::hid-last device))
        (events nil))
    (dotimes (bit 8)
      (unless (eq (logbitp bit (aref report 0)) (logbitp bit (aref last 0)))
        (push (key-event device (aref +usb-modifiers+ bit) (logbitp bit (aref report 0))) events)))
    (loop :for i :from 2 :below 8 :for usage := (aref last i)
          :when (and (< 3 usage (length +usb-keys+)) (not (find usage report :start 2)))
            :do (push (key-event device (aref +usb-keys+ usage) nil) events))
    (loop :for i :from 2 :below 8 :for usage := (aref report i)
          :when (and (< 3 usage (length +usb-keys+)) (not (find usage last :start 2)))
            :do (push (key-event device (aref +usb-keys+ usage) t) events))
    (setf (finch/iokit::hid-last device) report)
    (nreverse events)))

(defun signed-8 (b) (if (> b 127) (- b 256) b))

(defun mouse-report (device report)
  (let ((last (finch/iokit::hid-last device))
        (events nil))
    (loop :for bit :below 3 :for code :in '(#x110 #x111 #x112)
          :unless (eq (logbitp bit (aref report 0)) (logbitp bit (aref last 0)))
            :do (push (key-event device code (logbitp bit (aref report 0))) events))
    (unless (zerop (aref report 1))
      (push (make-hid-event :seconds 0 :type 2 :code 0 :value (signed-8 (aref report 1)) :fd device) events))
    (unless (zerop (aref report 2))
      (push (make-hid-event :seconds 0 :type 2 :code 1 :value (signed-8 (aref report 2)) :fd device) events))
    (setf (finch/iokit::hid-last device) report)
    (nreverse events)))

(defmethod read-events ((d finch/iokit::io-usb-hid-device))
  (loop :for report :in (finch/iokit::hid-reports d)
        :append (if (= (finch/iokit::hid-protocol d) 1) (keyboard-report d report) (mouse-report d report))))

(defmethod abs-range ((d finch/iokit::io-usb-hid-device) axis) (declare (ignore axis)) nil)
(defmethod event-vector ((d finch/iokit::io-usb-hid-device)) nil)

(defmethod read-events ((d finch/iokit::io-i2c-hid-device))
  (unless (finch/iokit::hid-fields d)
    (setf (finch/iokit::hid-fields d) (parse-report-descriptor (finch/iokit::hid-report-descriptor d))))
  (loop :for report :in (finch/iokit::i2c-hid-reports d)
        :append (multiple-value-bind (events state)
                    (pointer-events d (finch/iokit::hid-fields d) report (finch/iokit::hid-state d))
                  (setf (finch/iokit::hid-state d) state)
                  events)))

(defmethod abs-range ((d finch/iokit::io-i2c-hid-device) axis) (declare (ignore axis)) nil)
(defmethod event-vector ((d finch/iokit::io-i2c-hid-device)) nil)

(defun input-devices ()
  (finch/iokit:start-iokit)
  (append (finch/iokit:find-entries 'finch/iokit:apple-virtio-input)
          (finch/iokit:find-entries 'finch/iokit::io-usb-hid-device)
          (finch/iokit:find-entries 'finch/iokit::io-i2c-hid-device)
          (list *ps2-keyboard*)))
