(in-package #:finch/io)

(defstruct (hid-event (:conc-name event-)) seconds type code value fd)

(defun open-hid (device)
  (sb-posix:open device (logior sb-posix:o-rdonly sb-posix:o-nonblock)))

(defgeneric read-events (device))
(defgeneric abs-range (device axis))

(defmethod read-events ((in finch/iokit:apple-virtio-input))
  (loop for (type code value) in (finch/iokit:input-events in)
        collect (make-hid-event :seconds 0 :type type :code code :value value :fd in)))

(defmethod abs-range ((in finch/iokit:apple-virtio-input) axis) (finch/iokit:input-abs-range in axis))

(defgeneric event-vector (device))
(defmethod event-vector ((in finch/iokit:apple-virtio-input)) (finch/iokit:interrupt-vector in))
(defmethod event-vector ((fd integer)) nil)

(defun wait-for-events (devices)
  (let ((vectors (mapcar #'event-vector devices)))
    (if (and vectors (every #'identity vectors))
        (finch/iokit:wait-for-interrupt vectors)
        (sleep 0.005))))

(defun input-devices ()
  (if (probe-file "/dev/input/")
      (loop for file in (directory "/dev/input/event*")
            collect (open-hid (namestring file)))
      (progn (finch/iokit:start-iokit)
             (finch/iokit:find-entries 'finch/iokit:apple-virtio-input))))

(defmethod read-events ((fd integer))
  (let ((buffer (make-array (* 24 64) :element-type '(unsigned-byte 8))))
    (let ((n (handler-case (sb-sys:with-pinned-objects (buffer)
                             (sb-posix:read fd (sb-sys:vector-sap buffer) (length buffer)))
               (sb-posix:syscall-error () 0))))
      (loop :for at :from 0 :below n :by 24
            :collect (flet ((le (start size)
                              (loop :for i :below size :sum (ash (aref buffer (+ at start i)) (* 8 i)))))
                       (let ((value (le 20 4)))
                         (make-hid-event :seconds (le 0 8) :type (le 16 2) :code (le 18 2) :fd fd
                                         :value (if (logbitp 31 value) (- value (ash 1 32)) value))))))))

(defun eviocgabs (axis) (+ #x80184540 axis))

(defmethod abs-range ((fd integer) axis)
  (sb-alien:with-alien ((info (array (sb-alien:signed 32) 6)))
    (if (zerop (sb-alien:alien-funcall
                (sb-alien:extern-alien "ioctl" (function sb-alien:int sb-alien:int sb-alien:unsigned-long
                                                         (* (array (sb-alien:signed 32) 6))))
                fd (eviocgabs axis) (sb-alien:addr info)))
        (cons (sb-alien:deref info 1) (sb-alien:deref info 2))
        nil)))
