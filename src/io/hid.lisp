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

(defun input-devices ()
  (finch/iokit:start-iokit)
  (append (finch/iokit:find-entries 'finch/iokit:apple-virtio-input) (list *ps2-keyboard*)))
