(in-package #:darterfly/net)

(defconstant +dhcp-magic+ #x63825363)

(defun dhcp-message (xid type options)
  (let ((v (make-array 240 :element-type '(unsigned-byte 8) :initial-element 0)))
    (setf (aref v 0) 1 (aref v 1) 1 (aref v 2) 6)
    (replace v (be xid 4) :start1 4)
    (replace v (be #x8000 2) :start1 10)
    (replace v (interface-mac *interface*) :start1 28)
    (replace v (be +dhcp-magic+ 4) :start1 236)
    (octets v (octets (be 53 1) (be 1 1) (be type 1))
            (apply #'octets (loop for (code value) on options by #'cddr collect (octets (be code 1) (be (length value) 1) value)))
            (octets (be 55 1) (be 6 1) (octets (be 1 1) (be 3 1) (be 6 1) (be 15 1) (be 51 1) (be 54 1)))
            (be 255 1))))

(defun dhcp-options (v)
  (let ((options (make-hash-table)))
    (loop with at = 240
          while (< at (length v))
          do (let ((code (aref v at)))
               (case code
                 (0 (incf at))
                 (255 (return))
                 (t (let ((n (aref v (1+ at))))
                      (setf (gethash code options) (subseq v (+ at 2) (+ at 2 n)))
                      (incf at (+ 2 n)))))))
    options))

(defun dhcp-reply (port xid type timeout)
  (loop
    (let ((data (udp-receive port :timeout timeout)))
      (unless data (return nil))
      (when (and (>= (length data) 240) (= (aref data 0) 2) (= (u32be data 4) xid) (= (u32be data 236) +dhcp-magic+))
        (let ((options (dhcp-options data)))
          (when (eql (aref (gethash 53 options #(0)) 0) type)
            (return (values (u32be data 16) options))))))))

(defun prefix-length (mask) (logcount mask))

(defun dhcp (&key (tries 4) (timeout 2)
                  (device (and *interface* (interface-device *interface*))))
  (sb-thread:with-recursive-lock (*configuration-lock*)
    (let ((interface *interface*) (epoch *interface-epoch*))
      (flet ((ensure-current ()
               (unless (and device (eq interface *interface*)
                            (eq device (interface-device interface))
                            (= epoch *interface-epoch*))
                 (net-fail :enetdown "dhcp: interface attachment changed"))))
        (ensure-current)
        (let ((port (udp-bind 68))
              (xid (random (ash 1 32) (make-random-state t))))
          (unwind-protect
               (dotimes (try tries (net-fail :etimedout "dhcp: no lease"))
                 (ensure-current)
                 (udp-send #xffffffff 68 67 (dhcp-message xid 1 nil))
                 (multiple-value-bind (offer options) (dhcp-reply port xid 2 timeout)
                   (ensure-current)
                   (when offer
                     (let ((server (gethash 54 options)))
                       (udp-send #xffffffff 68 67 (dhcp-message xid 3 (list 50 (be offer 4) 54 server)))
                       (multiple-value-bind (ip options) (dhcp-reply port xid 5 timeout)
                         (when ip
                           ;; Never publish a delayed lease into another selection,
                           ;; including detach/reattach of the same device object.
                           (sb-thread:with-mutex ((interface-lock interface))
                             (ensure-current)
                             (setf (interface-ip interface) ip
                                   (interface-prefix interface) (prefix-length (u32be (gethash 1 options (be #xffffff00 4)) 0))
                                   (interface-gateway interface) (let ((r (gethash 3 options))) (if r (u32be r 0) 0))
                                   (interface-dns interface) (let ((d (gethash 6 options))) (when d (loop for at from 0 below (length d) by 4 collect (u32be d at))))
                                   (interface-lease interface) (let ((l (gethash 51 options))) (when l (u32be l 0)))))
                           (return ip)))))))
            (let ((*interface* interface)) (udp-close port))))))))
