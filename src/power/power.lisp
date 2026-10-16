(defpackage #:finch/power
  (:use #:cl)
  (:export #:flush-disks #:restart #:shut-down #:restart-soon)
  (:shadow #:restart))
(in-package #:finch/power)

(defun flush-disks ()
  (finch/vfs:vfs-sync)
  (dolist (m (finch/devices:find-entries 'finch/devices:media))
    (when (finch/devices:get-property m "Whole")
      (ignore-errors (finch/devices:media-flush m)))))

(defun restart ()
  (flush-disks)
  (finch/devices:machdep 26))

(defun restart-soon (&optional (seconds 2))
  (sb-thread:make-thread (lambda () (sleep seconds) (restart)) :name "restart")
  :restarting)

(defun package-integer (v at)
  (case (aref v at)
    (0 (values 0 1))
    (1 (values 1 1))
    (#x0a (values (aref v (1+ at)) 2))
    (#x0b (values (logior (aref v (1+ at)) (ash (aref v (+ at 2)) 8)) 3))))

(defun s5-sleep-type ()
  (loop for v in (finch/devices::definition-blocks)
        for at = (search #(8 95 83 53 95 18) v)
        when at
          return (let ((p (+ at 6)))
                   (multiple-value-bind (length used) (finch/devices::aml-pkg-length v p)
                     (declare (ignore length))
                     (package-integer v (+ p used 1))))))

(defun shut-down ()
  (let* ((fadt (finch/devices::acpi-table "FACP"))
         (port (and fadt (finch/devices::ml-phys-read-32 (+ fadt 64))))
         (type (s5-sleep-type)))
    (unless (and port (plusp port) type)
      (error "shut down: no ACPI sleep control"))
    (flush-disks)
    (finch/devices:machdep 27 port (logior (ash type 10) (ash 1 13)))))
