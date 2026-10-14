(defpackage #:finch/net
  (:use #:cl)
  (:export #:start-network #:*interface* #:ping #:udp-bind #:udp-close #:udp-send #:udp-receive #:udp-echo
           #:ip-address #:address-string #:dhcp #:resolve-name
           #:if-output #:net-error #:net-errno #:listener #:connection #:port
           #:tcp-listen #:tcp-unlisten #:tcp-peer #:tcp-reset-p #:tcp-accept #:tcp-connect #:tcp-send #:tcp-receive #:tcp-close #:tcp-echo))
(in-package #:finch/net)

(defstruct interface device mac (ip 0) (prefix 0) (gateway 0) dns lease ip6 router6 dns6
  (arp (make-hash-table)) (nd6 (make-hash-table :test 'equalp)) (ports (make-hash-table)) (pings (make-hash-table :test 'equalp))
  (lock (sb-thread:make-mutex :name "net")) (changed (sb-thread:make-waitqueue)) (id 0) thread)

(defvar *interface* nil)

(define-condition net-error (error)
  ((errno :initarg :errno :reader net-errno)
   (message :initarg :message :reader net-message))
  (:report (lambda (c s) (format s "~a: ~a" (net-errno c) (net-message c)))))

(defun net-fail (errno control &rest args)
  (error 'net-error :errno errno :message (apply #'format nil control args)))

(defun ip-address (string)
  (if (find #\: string)
      (ip6-address string)
      (ip4-address string)))

(defun ip4-address (string)
  (reduce (lambda (a b) (logior (ash a 8) b)) (mapcar #'parse-integer (uiop:split-string string :separator "."))))

(defun address-string (ip) (if (ip6-p ip) (ip6-string ip) (ip4-string ip)))

(defun ip4-string (ip) (format nil "~{~d~^.~}" (loop for s from 24 downto 0 by 8 collect (ldb (byte 8 s) ip))))

(defun u16be (v at) (logior (ash (aref v at) 8) (aref v (1+ at))))
(defun u32be (v at) (logior (ash (u16be v at) 16) (u16be v (+ at 2))))

(defun octets (&rest parts)
  (let ((out (make-array 0 :element-type '(unsigned-byte 8) :adjustable t :fill-pointer 0)))
    (dolist (p parts (coerce out '(simple-array (unsigned-byte 8) (*))))
      (etypecase p
        (vector (loop for b across p do (vector-push-extend b out)))))))

(defun be (n width)
  (let ((v (make-array width :element-type '(unsigned-byte 8))))
    (dotimes (i width v) (setf (aref v (- width 1 i)) (ldb (byte 8 (* 8 i)) n)))))

(defun checksum (v &key (start 0) (end (length v)) (initial 0))
  (let ((sum initial))
    (loop for i from start below end by 2
          do (incf sum (logior (ash (aref v i) 8) (if (< (1+ i) end) (aref v (1+ i)) 0))))
    (loop while (> sum #xffff) do (setf sum (+ (logand sum #xffff) (ash sum -16))))
    (logxor sum #xffff)))

(defconstant +ethertype-ip+ #x0800)
(defconstant +ethertype-arp+ #x0806)
(defconstant +ethertype-ip6+ #x86dd)
(defparameter +broadcast+ (make-array 6 :element-type '(unsigned-byte 8) :initial-element #xff))

(defgeneric if-output (device frame))

(defmethod if-output ((device finch/iokit:apple-virtio-network) frame)
  (finch/iokit:network-send device frame))

(defun send-frame (dst type payload)
  (if-output (interface-device *interface*) (octets dst (interface-mac *interface*) (be type 2) payload)))

(defun arp-packet (op target-mac target-ip)
  (octets (be 1 2) (be +ethertype-ip+ 2) (be 6 1) (be 4 1) (be op 2)
          (interface-mac *interface*) (be (interface-ip *interface*) 4) target-mac (be target-ip 4)))

(defun on-link-p (ip)
  (let ((mask (logand #xffffffff (ash #xffffffff (- 32 (interface-prefix *interface*))))))
    (= (logand ip mask) (logand (interface-ip *interface*) mask))))

(defun resolve (ip)
  (when (= ip #xffffffff) (return-from resolve +broadcast+))
  (let ((hop (if (on-link-p ip) ip (interface-gateway *interface*)))
        (if *interface*))
    (dotimes (try 4 (net-fail :ehostunreach "arp: no answer from ~a" (address-string hop)))
      (sb-thread:with-mutex ((interface-lock if))
        (let ((mac (gethash hop (interface-arp if))))
          (when mac (return mac))))
      (send-frame +broadcast+ +ethertype-arp+ (arp-packet 1 (make-array 6 :element-type '(unsigned-byte 8) :initial-element 0) hop))
      (sb-thread:with-mutex ((interface-lock if))
        (unless (gethash hop (interface-arp if))
          (sb-thread:condition-wait (interface-changed if) (interface-lock if) :timeout 0.5))))))

(defun receive-arp (packet)
  (let ((op (u16be packet 6)) (sha (subseq packet 8 14)) (spa (u32be packet 14)) (tpa (u32be packet 24))
        (if *interface*))
    (sb-thread:with-mutex ((interface-lock if))
      (setf (gethash spa (interface-arp if)) sha)
      (sb-thread:condition-broadcast (interface-changed if)))
    (when (and (= op 1) (= tpa (interface-ip if)))
      (send-frame sha +ethertype-arp+ (arp-packet 2 sha spa)))))

(defun send-ip (protocol dst payload)
  (if (ip6-p dst)
      (send-ip6 protocol dst payload)
      (send-ip4 protocol dst payload)))

(defun send-ip4 (protocol dst payload)
  (let* ((if *interface*)
         (header (octets (be #x45 1) (be 0 1) (be (+ 20 (length payload)) 2)
                         (be (ldb (byte 16 0) (incf (interface-id if))) 2) (be #x4000 2)
                         (be 64 1) (be protocol 1) (be 0 2) (be (interface-ip if) 4) (be dst 4))))
    (replace header (be (checksum header) 2) :start1 10)
    (send-frame (resolve dst) +ethertype-ip+ (octets header payload))))

(defun receive-icmp (src packet)
  (case (aref packet 0)
    (8 (let ((reply (copy-seq packet)))
         (setf (aref reply 0) 0 (aref reply 2) 0 (aref reply 3) 0)
         (replace reply (be (checksum reply) 2) :start1 2)
         (send-ip 1 src reply)))
    (0 (let ((if *interface*))
         (sb-thread:with-mutex ((interface-lock if))
           (setf (gethash (list src (u16be packet 4) (u16be packet 6)) (interface-pings if)) (get-internal-real-time))
           (sb-thread:condition-broadcast (interface-changed if)))))))

(defun ping (address &key (id 1) (sequence 1) (timeout 2))
  (let* ((dst (if (stringp address) (ip-address address) address))
         (body (octets (be id 2) (be sequence 2) (map '(vector (unsigned-byte 8)) #'char-code "finch")))
         (if *interface*)
         (key (list dst id sequence))
         (sent (get-internal-real-time)))
    (if (ip6-p dst)
        (send-icmp6 128 0 body dst :hops 64)
        (let ((packet (octets (be 8 1) (be 0 1) (be 0 2) body)))
          (replace packet (be (checksum packet) 2) :start1 2)
          (send-ip 1 dst packet)))
    (sb-thread:with-mutex ((interface-lock if))
      (loop for got = (gethash key (interface-pings if))
            when got return (/ (- got sent) (float internal-time-units-per-second))
            unless (sb-thread:condition-wait (interface-changed if) (interface-lock if) :timeout timeout)
              return nil))))

(defstruct port number (queue nil) (lock (sb-thread:make-mutex :name "udp")) (ready (sb-thread:make-waitqueue)))

(defun udp-bind (number)
  (sb-thread:with-mutex ((interface-lock *interface*))
    (setf (gethash number (interface-ports *interface*)) (make-port :number number))))

(defun udp-close (port)
  (sb-thread:with-mutex ((interface-lock *interface*))
    (remhash (port-number port) (interface-ports *interface*))))

(defun udp-send (address src-port dst-port data)
  (let ((dst (if (stringp address) (ip-address address) address)))
    (let ((datagram (octets (be src-port 2) (be dst-port 2) (be (+ 8 (length data)) 2) (be 0 2) data)))
      (replace datagram (be (transport-checksum (source-address dst) dst 17 datagram) 2) :start1 6)
      (send-ip 17 dst datagram))))

(defun udp-receive (port &key timeout)
  (sb-thread:with-mutex ((port-lock port))
    (loop until (port-queue port)
          do (unless (sb-thread:condition-wait (port-ready port) (port-lock port) :timeout timeout)
               (unless (port-queue port) (return-from udp-receive nil))))
    (let ((d (car (last (port-queue port)))))
      (setf (port-queue port) (butlast (port-queue port)))
      (values-list d))))

(defun receive-udp (src packet)
  (let ((port (sb-thread:with-mutex ((interface-lock *interface*))
                (gethash (u16be packet 2) (interface-ports *interface*)))))
    (when port
      (sb-thread:with-mutex ((port-lock port))
        (push (list (subseq packet 8 (u16be packet 4)) src (u16be packet 0)) (port-queue port))
        (sb-thread:condition-broadcast (port-ready port))))))

(defun receive-ip (packet)
  (let* ((ihl (* 4 (logand (aref packet 0) 15)))
         (total (u16be packet 2))
         (protocol (aref packet 9))
         (src (u32be packet 12))
         (dst (u32be packet 16))
         (payload (subseq packet ihl (min total (length packet)))))
    (when (or (= dst (interface-ip *interface*)) (= dst #xffffffff) (zerop (interface-ip *interface*)))
      (case protocol
        (1 (receive-icmp src payload))
        (6 (receive-tcp src payload))
        (17 (receive-udp src payload))))))

(defun receive-frame (frame)
  (when (>= (length frame) 14)
    (let ((type (u16be frame 12)) (payload (subseq frame 14)))
      (cond ((= type +ethertype-arp+) (receive-arp payload))
            ((= type +ethertype-ip+) (receive-ip payload))
            ((= type +ethertype-ip6+) (receive-ip6 payload))))))

(defun input-loop ()
  (let* ((device (interface-device *interface*))
         (vector (finch/iokit:interrupt-vector device)))
    (loop
      (let ((frames (finch/iokit:network-receive device)))
        (cond (frames (dolist (f frames) (ignore-errors (receive-frame f))))
              (vector (finch/iokit:wait-for-interrupt (list vector)))
              (t (sleep 0.002)))))))

(defun start-network (&key ip (prefix 24) gateway)
  (finch/iokit:start-iokit)
  (let ((device (first (finch/iokit:find-entries 'finch/iokit:apple-virtio-network))))
    (unless device (net-fail :enetdown "no network device"))
    (setf *interface* (make-interface :device device :mac (finch/iokit:network-mac device)))
    (setf (interface-thread *interface*) (sb-thread:make-thread #'input-loop :name "net input"))
    (start-ip6)
    (if ip
        (setf (interface-ip *interface*) (ip-address ip) (interface-prefix *interface*) prefix
              (interface-gateway *interface*) (if gateway (ip-address gateway) 0))
        (dhcp))
    *interface*))

(defun udp-echo (number)
  (let ((port (udp-bind number)))
    (sb-thread:make-thread
     (lambda ()
       (loop (multiple-value-bind (data src src-port) (udp-receive port)
               (when data (udp-send src number src-port data)))))
     :name (format nil "udp echo ~d" number))))
