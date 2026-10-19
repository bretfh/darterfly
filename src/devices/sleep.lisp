(in-package #:darterfly/devices)

(defgeneric suspend (service)
  (:method ((service entry)) t))

(defgeneric wake (service)
  (:method ((service entry)) t))

(defvar *saved-config* (make-hash-table :test 'eq :weakness :key))

(defmethod suspend :after ((d pci-node))
  (setf (gethash d *saved-config*)
        (coerce (loop for at below 256 by 4 collect (config-read-32 d at)) '(vector (unsigned-byte 32)))))

(defmethod wake :before ((d pci-node))
  (let ((saved (gethash d *saved-config*)))
    (when saved
      (loop for i from 63 downto 2
            unless (= (config-read-32 d (* 4 i)) (aref saved i))
              do (config-write-32 d (* 4 i) (aref saved i)))
      (config-write-16 d 4 (ldb (byte 16 0) (aref saved 1))))))

(defun each-device (fn order &optional (root *registry-root*))
  (labels ((walk (e)
             (when (eq order :parents-first) (call fn e))
             (mapc #'walk (entry-children e))
             (when (eq order :children-first) (call fn e)))
           (call (fn e)
             (handler-case (funcall fn e)
               (error (c) (format *error-output* "~&device ~a: ~a~%" (entry-name e) c)))))
    (when root (walk root))))

(defun suspend-devices ()
  (when *registry-root* (announce :suspending *registry-root*))
  (each-device #'suspend :children-first))
(defun wake-devices ()
  (each-device #'wake :parents-first)
  (when *registry-root* (announce :woke *registry-root*)))
