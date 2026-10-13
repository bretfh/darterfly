(in-package #:finch/io)

(defstruct (hid-event (:conc-name event-)) seconds type code value fd)

(defun open-hid (device)
  (sb-posix:open device (logior sb-posix:o-rdonly sb-posix:o-nonblock)))

(defun read-events (fd)
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

(defun abs-range (fd axis)
  (sb-alien:with-alien ((info (array (sb-alien:signed 32) 6)))
    (if (zerop (sb-alien:alien-funcall
                (sb-alien:extern-alien "ioctl" (function sb-alien:int sb-alien:int sb-alien:unsigned-long
                                                         (* (array (sb-alien:signed 32) 6))))
                fd (eviocgabs axis) (sb-alien:addr info)))
        (cons (sb-alien:deref info 1) (sb-alien:deref info 2))
        nil)))
