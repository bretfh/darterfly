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

(defun input-devices ()
  (finch/iokit:start-iokit)
  (finch/iokit:find-entries 'finch/iokit:apple-virtio-input))
