(in-package #:darterfly/test)

(def-suite net :in host)
(in-suite net)

(defclass captured-device () ((frames :initform nil :accessor frames)))

(defmethod darterfly/net:if-output ((device captured-device) frame)
  (push frame (frames device)))

(defparameter +peer-mac+ (coerce #(2 0 0 0 0 2) '(vector (unsigned-byte 8))))

(defun peer-segment (seq ack flags &optional (data ""))
  (let ((d (sb-ext:string-to-octets data)))
    (darterfly/net::octets (darterfly/net::be 5000 2) (darterfly/net::be 80 2) (darterfly/net::be seq 4) (darterfly/net::be ack 4)
                       (darterfly/net::be #x50 1) (darterfly/net::be flags 1) (darterfly/net::be 65535 2) (darterfly/net::be 0 4) d)))

(defun last-segment (device)
  (subseq (first (frames device)) 34))

(defun last-ack (device) (darterfly/net::u32be (last-segment device) 8))

(test tcp-reassembles-out-of-order-segments
  (let* ((device (make-instance 'captured-device))
         (peer (darterfly/net:ip-address "10.0.2.2"))
         (darterfly/net:*interface* (darterfly/net::make-interface :device device :mac (coerce #(2 0 0 0 0 1) '(vector (unsigned-byte 8)))
                                                           :ip (darterfly/net:ip-address "10.0.2.15") :prefix 24 :gateway peer))
         (darterfly/net::*connections* (make-hash-table :test 'equalp))
         (darterfly/net::*listeners* (make-hash-table)))
    (setf (gethash peer (darterfly/net::interface-arp darterfly/net:*interface*)) +peer-mac+)
    (let ((listener (darterfly/net:tcp-listen 80)))
        (darterfly/net::receive-tcp peer (peer-segment 1000 0 darterfly/net::+syn+))
        (let* ((syn-ack (last-segment device))
               (iss (darterfly/net::u32be syn-ack 4))
               (ack-flags darterfly/net::+ack+))
          (is (= 1001 (last-ack device)))
          (darterfly/net::receive-tcp peer (peer-segment 1001 (1+ iss) ack-flags))
          (let ((c (darterfly/net:tcp-accept listener :timeout 1)))
            (is (not (null c)))
            (flet ((in (seq &optional (data "") (flags ack-flags)) (darterfly/net::receive-tcp peer (peer-segment seq (1+ iss) flags data)))
                   (got () (let ((v (darterfly/net:tcp-receive c :timeout 0))) (and v (map 'string #'code-char v)))))
              (in 1007 "ccc")
              (is (= 1001 (last-ack device)) "a segment past a gap is held and the old ack repeated")
              (in 1004 "bbb")
              (is (= 1001 (last-ack device)))
              (is (equal "" (got)))
              (in 1001 "aaa")
              (is (= 1010 (last-ack device)) "the gap filled, everything held is delivered")
              (is (equal "aaabbbccc" (got)))
              (in 1007 "cccddd")
              (is (= 1013 (last-ack device)) "an overlapping retransmission gives only its new bytes")
              (is (equal "ddd" (got)))
              (in 1001 "aaa")
              (is (= 1013 (last-ack device)) "an old duplicate is re-acked")
              (is (equal "" (got)))
              (in 1016 "fff" (logior ack-flags darterfly/net::+fin+))
              (in 1013 "eee")
              (is (= 1020 (last-ack device)) "a held FIN counts once the data before it arrives")
              (is (equal "eeefff" (got)))
              (is (null (got)) "end of stream")
              (is (eq :close-wait (darterfly/net::tcp-state c)))))))))

(defun data-segments (device)
  (loop for frame in (reverse (frames device))
        for segment = (subseq frame 34)
        when (> (length segment) (* 4 (ash (aref segment 12) -4)))
          collect (darterfly/net::u32be segment 4)))

(test tcp-congestion-control
  (let* ((device (make-instance 'captured-device))
         (peer (darterfly/net:ip-address "10.0.2.2"))
         (darterfly/net:*interface* (darterfly/net::make-interface :device device :mac (coerce #(2 0 0 0 0 1) '(vector (unsigned-byte 8)))
                                                           :ip (darterfly/net:ip-address "10.0.2.15") :prefix 24 :gateway peer))
         (darterfly/net::*connections* (make-hash-table :test 'equalp))
         (darterfly/net::*listeners* (make-hash-table))
         (mss darterfly/net::+mss+))
    (setf (gethash peer (darterfly/net::interface-arp darterfly/net:*interface*)) +peer-mac+)
    (let ((listener (darterfly/net:tcp-listen 80)))
      (darterfly/net::receive-tcp peer (peer-segment 1000 0 darterfly/net::+syn+))
      (let* ((iss (darterfly/net::u32be (last-segment device) 4))
             (base (1+ iss)))
        (darterfly/net::receive-tcp peer (peer-segment 1001 base darterfly/net::+ack+))
        (let ((c (darterfly/net:tcp-accept listener :timeout 1)))
          (flet ((ack (n) (darterfly/net::receive-tcp peer (peer-segment 1001 (+ base (* n mss)) darterfly/net::+ack+))))
            (darterfly/net:tcp-send c (make-array (* 20 mss) :element-type '(unsigned-byte 8) :initial-element 7))
            (is (= 10 (length (data-segments device))) "slow start begins with ten segments")
            (ack 1)
            (is (= 12 (length (data-segments device))) "each ack in slow start opens the window by a segment")
            (is (= (* 11 mss) (darterfly/net::tcp-snd-cwnd c)))
            (ack 1) (ack 1)
            (is (= 12 (length (data-segments device))) "two duplicate acks retransmit nothing")
            (ack 1)
            (is (= (+ base mss) (first (last (data-segments device)))) "the third retransmits the lost segment")
            (is (= (* 5 mss) (darterfly/net::tcp-snd-ssthresh c)) "ssthresh is half the window")
            (is (= (* 8 mss) (darterfly/net::tcp-snd-cwnd c)) "cwnd is ssthresh plus the three segments that left")
            (ack 2)
            (is (= (+ base (* 2 mss)) (first (last (data-segments device)))) "a partial ack retransmits the next hole")
            (ack 12)
            (is (null (darterfly/net::tcp-snd-recover c)) "an ack past the recovery point ends fast recovery")
            (is (= (* 5 mss) (darterfly/net::tcp-snd-ssthresh c)))
            (is (<= (darterfly/net::tcp-snd-cwnd c) (* 5 mss)) "and deflates cwnd to ssthresh")
            (is (<= 1 (darterfly/net::tcp-rxtcur c) 64) "the retransmit timeout follows the measured round trip")))))))

(defun peer-ip6 (src dst next payload &optional (hops 255))
  (darterfly/net::octets (darterfly/net::be #x60000000 4) (darterfly/net::be (length payload) 2) (darterfly/net::be next 1) (darterfly/net::be hops 1)
                     src dst payload))

(defun peer-icmp6 (src dst type body)
  (peer-ip6 src dst 58 (darterfly/net::icmp6-packet type 0 body src dst)))

(test ip6-addresses-and-neighbor-discovery
  (flet ((a (s) (darterfly/net:ip-address s)))
    (dolist (s '("fec0::5054:ff:fe12:3456" "::1" "::" "fe80::1" "2001:db8::1:0:0:1" "2001:db8:0:1:1:1:1:1" "ff02::1:ff12:3456"))
      (is (equal s (darterfly/net:address-string (a s)))))
    (is (equal "2001:db8::1:0:0:1" (darterfly/net:address-string (a "2001:0db8:0000:0000:0001:0000:0000:0001"))) "the longest zero run, leftmost on ties")
    (is (equal "10.0.2.2" (darterfly/net:address-string (a "10.0.2.2"))))
    (let* ((device (make-instance 'captured-device))
           (mac (coerce #(#x52 #x54 0 #x12 #x34 #x56) '(vector (unsigned-byte 8))))
           (router (a "fe80::2"))
           (darterfly/net:*interface* (darterfly/net::make-interface :device device :mac mac))
           (darterfly/net::*connections* (make-hash-table :test 'equalp))
           (darterfly/net::*listeners* (make-hash-table)))
      (darterfly/net::start-ip6)
      (let ((rs (first (frames device))))
        (is (equalp #(#x33 #x33 0 0 0 2) (subseq rs 0 6)) "the router solicitation goes to all-routers")
        (is (= 133 (aref rs 54))))
      (is (equal '("fe80::5054:ff:fe12:3456") (mapcar #'darterfly/net:address-string (darterfly/net::interface-ip6 darterfly/net:*interface*))))
      (setf (gethash router (darterfly/net::interface-nd6 darterfly/net:*interface*)) +peer-mac+)
      (darterfly/net::receive-ip6
       (peer-icmp6 router (a "ff02::1") 134
                   (darterfly/net::octets (darterfly/net::be 64 1) (darterfly/net::be 0 1) (darterfly/net::be 1800 2) (darterfly/net::be 0 8)
                                      (darterfly/net::be 3 1) (darterfly/net::be 4 1) (darterfly/net::be 64 1) (darterfly/net::be #xc0 1)
                                      (darterfly/net::be 86400 4) (darterfly/net::be 14400 4) (darterfly/net::be 0 4) (a "fec0::")
                                      (darterfly/net::be 25 1) (darterfly/net::be 3 1) (darterfly/net::be 0 2) (darterfly/net::be 3600 4) (a "fec0::3"))))
      (is (equal '("fe80::5054:ff:fe12:3456" "fec0::5054:ff:fe12:3456")
                 (mapcar #'darterfly/net:address-string (darterfly/net::interface-ip6 darterfly/net:*interface*)))
          "the advertised prefix and the interface identifier make an address")
      (is (equalp router (darterfly/net::interface-router6 darterfly/net:*interface*)))
      (is (equal '("fec0::3") (mapcar #'darterfly/net:address-string (darterfly/net::interface-dns6 darterfly/net:*interface*))))
      (let ((ours (a "fec0::5054:ff:fe12:3456")) (peer (a "fec0::2")))
        (darterfly/net::receive-ip6
         (peer-icmp6 peer (darterfly/net::solicited-node ours) 135
                     (darterfly/net::octets (darterfly/net::be 0 4) ours (darterfly/net::be 1 1) (darterfly/net::be 1 1) +peer-mac+)))
        (let* ((frame (first (frames device))) (icmp (subseq frame 54)))
          (is (= 136 (aref icmp 0)) "a solicitation for our address is answered")
          (is (equalp ours (subseq icmp 8 24)))
          (is (zerop (darterfly/net::transport-checksum (subseq frame 22 38) (subseq frame 38 54) 58 icmp))))
        (is (equalp +peer-mac+ (gethash peer (darterfly/net::interface-nd6 darterfly/net:*interface*))) "and the solicitor is learned")
        (let ((listener (darterfly/net:tcp-listen 80)))
          (darterfly/net::receive-ip6 (peer-ip6 peer ours 6 (let ((s (peer-segment 1000 0 darterfly/net::+syn+)))
                                                          (replace s (darterfly/net::be (darterfly/net::transport-checksum peer ours 6 s) 2) :start1 16))))
          (let* ((frame (first (frames device))) (segment (subseq frame 54)))
            (is (= #x86dd (darterfly/net::u16be frame 12)))
            (is (= (logior darterfly/net::+syn+ darterfly/net::+ack+) (aref segment 13)) "a SYN over IPv6 is answered")
            (is (zerop (darterfly/net::transport-checksum ours peer 6 segment)))
            (is (= 1440 (darterfly/net::u16be segment 22)) "with the IPv6 segment size")
            (darterfly/net:tcp-unlisten listener)))))))

(test a-retransmit-into-a-dead-link-does-not-stop-the-tcp-timer
  (let* ((darterfly/net::*connections* (make-hash-table :test 'equalp))
         (c (darterfly/net::make-connection :state :established :snd-una 1 :snd-nxt 11 :rxtcur 0.01
                                            :unacked (list (list 1 darterfly/net::+ack+ (make-array 10 :element-type '(unsigned-byte 8) :initial-element 0)
                                                                 (- (get-internal-real-time) internal-time-units-per-second) 0)))))
    (setf (gethash :key darterfly/net::*connections*) c)
    (sb-int:encapsulate 'darterfly/net::send-segment 'dead-link
                        (lambda (f &rest args) (declare (ignore f args)) (darterfly/net::net-fail :ehostunreach "arp: no answer")))
    (unwind-protect
         (progn
           (finishes (darterfly/net::tcp-tick))
           (is (eq c (gethash :key darterfly/net::*connections*)) "the connection waits for the link to come back")
           (is (= 1 (fifth (first (darterfly/net::tcp-unacked c)))) "the failed try still counts toward giving up"))
      (sb-int:unencapsulate 'darterfly/net::send-segment 'dead-link))))

(defmacro with-timeouts-that-drop-the-mutex (&body body)
  `(progn
     (sb-int:encapsulate 'sb-thread:condition-wait 'drop
                         (lambda (f queue mutex &key timeout)
                           (declare (ignore f queue))
                           (unless (sb-thread:holding-mutex-p mutex)
                             (error "The current thread is not holding ~s." mutex))
                           (when timeout (sleep (min timeout 0.05)))
                           (sb-thread:release-mutex mutex)
                           nil))
     (unwind-protect (progn ,@body)
       (sb-int:unencapsulate 'sb-thread:condition-wait 'drop))))

(test a-wait-whose-timeout-drops-the-mutex-carries-on
  (with-timeouts-that-drop-the-mutex
    (is (null (darterfly/devices:wait-for-interrupt (list darterfly/devices::+input-vector+) 0.2)) "an interrupt wait times out cleanly")
    (let ((darterfly/net:*interface* (darterfly/net::make-interface)))
      (is (null (darterfly/net:udp-receive (darterfly/net:udp-bind 40999) :timeout 0.2)) "and so does a udp receive"))
    (let ((darterfly/net:*interface* (darterfly/net::make-interface :device (make-instance 'captured-device) :mac +peer-mac+
                                                                    :ip (darterfly/net:ip-address "10.0.2.15") :prefix 24
                                                                    :gateway (darterfly/net:ip-address "10.0.2.2"))))
      (setf (gethash (darterfly/net:ip-address "10.0.2.2") (darterfly/net::interface-arp darterfly/net:*interface*)) +peer-mac+)
      (is (search "no answer" (handler-case (progn (darterfly/net::resolve (darterfly/net:ip-address "10.0.2.77")) "answered")
                                (darterfly/net::net-error (e) (princ-to-string e))))
          "an address that never answers arp is unreachable")
      (is (null (darterfly/net:ping "10.0.2.2" :timeout 0.2)) "a ping nobody answers times out")
      (is (search "no answer" (handler-case (progn (darterfly/net::nd6-resolve (darterfly/net:ip-address "fe80::77")) "answered")
                                (darterfly/net::net-error (e) (princ-to-string e))))
          "and so does one that never answers neighbor discovery"))))

(test exhausted-usb-transmit-does-not-overwrite-owned-dma
  (let* ((c (make-instance 'darterfly/devices::xhci-controller))
         (e (make-instance 'darterfly/devices::usb-cdc-ecm :controller c :slot 1))
         (writes 0) (failure nil))
    (setf (darterfly/devices::xhci-vector c) nil
          (darterfly/devices::ecm-in-flight e) (1- darterfly/devices::+ecm-send-pages+)
          (darterfly/devices::ecm-mps e) 512
          (darterfly/devices::ecm-send-pages e) (make-array darterfly/devices::+ecm-send-pages+ :initial-element 4096))
    (unwind-protect
         (progn
           (sb-int:encapsulate 'darterfly/devices::process-events 'stalled-usb
                              (lambda (&rest args) (declare (ignore args)) nil))
           (sb-int:encapsulate 'darterfly/devices:wait-for-interrupt 'stalled-usb
                              (lambda (&rest args) (declare (ignore args)) nil))
           (sb-int:encapsulate 'darterfly/devices::copy-to-phys 'stalled-usb
                              (lambda (&rest args) (declare (ignore args)) (incf writes) (error "DMA buffer reused")))
           (handler-case
               (darterfly/devices:network-send e (make-array 60 :element-type '(unsigned-byte 8) :initial-element 0))
             (error (e) (setf failure (princ-to-string e))))
           (is (and failure (search "transmit queue stalled" failure)))
           (is (zerop writes))
           (is (zerop (darterfly/devices::ecm-send-next e)))
           (is (= (1- darterfly/devices::+ecm-send-pages+) (darterfly/devices::ecm-in-flight e))))
      (dolist (f '(darterfly/devices::process-events darterfly/devices:wait-for-interrupt darterfly/devices::copy-to-phys))
        (sb-int:unencapsulate f 'stalled-usb)))))

(test tcp-reassembles-through-the-scaled-receive-window
  (let* ((c (darterfly/net::make-connection :state :established :rcv-nxt 1001 :rcv-scale 5))
         (gap 131072)
         (data (make-array gap :element-type '(unsigned-byte 8) :initial-element 90)))
    (is (> (ash (darterfly/net::advertised-window c darterfly/net::+ack+) 5) gap))
    (darterfly/net::receive-in-order c (+ 1001 gap) #(91 92) nil)
    (is (= 1 (length (darterfly/net::tcp-out-of-order c))) "retain data inside the window we advertised")
    (darterfly/net::receive-in-order c 1001 data nil)
    (is (= (+ gap 2) (length (darterfly/net::tcp-received c))) "filling a hole delivers the retained tail without retransmission")
    (is (= (+ 1001 gap 2) (darterfly/net::tcp-rcv-nxt c))))
  (dolist (scale '(0 5))
    (let* ((c (darterfly/net::make-connection :rcv-nxt #xfffffff0 :rcv-scale scale))
           (window (ash (darterfly/net::advertised-window c darterfly/net::+ack+) scale)))
      (darterfly/net::receive-in-order c (darterfly/net::seq+ #xfffffff0 window) #(1) nil)
      (is (null (darterfly/net::tcp-out-of-order c)) "do not retain data beyond the advertised window")))
  (let ((c (darterfly/net::make-connection :rcv-nxt 1001 :rcv-scale 5
             :received (make-array (- darterfly/net::+rcvbuf+ 32) :element-type '(unsigned-byte 8)))))
    (darterfly/net::receive-in-order c 1033 #(1) nil)
    (is (null (darterfly/net::tcp-out-of-order c)) "buffered unread data reduces the acceptable gap")))

(test a-usb-transmit-stall-does-not-terminate-delayed-acks
  (let* ((e (make-instance 'darterfly/devices::usb-cdc-ecm))
         (peer (darterfly/net:ip-address "10.0.2.2"))
         (darterfly/net:*interface* (darterfly/net::make-interface
                                    :device e :mac +peer-mac+ :ip (darterfly/net:ip-address "10.0.2.15")))
         (c (darterfly/net::make-connection :local-port 5000 :remote-port 5001
              :remote-ip peer :rcv-nxt 1001 :snd-nxt 2001 :ack-pending t))
         (darterfly/net::*acks-due* (list c)))
    (setf (gethash peer (darterfly/net::interface-arp darterfly/net:*interface*)) +peer-mac+)
    (unwind-protect
         (progn
           (sb-int:encapsulate 'darterfly/devices:network-send 'queue-failure
                              (lambda (&rest args) (declare (ignore args))
                                (error 'darterfly/devices::ethernet-transmit-stalled)))
           (is (eq :etimedout (handler-case (darterfly/net:if-output e #(1))
                             (darterfly/net:net-error (e) (darterfly/net:net-errno e)))))
           (finishes (darterfly/net::flush-acks))
           (is (null darterfly/net::*acks-due*)))
      (sb-int:unencapsulate 'darterfly/devices:network-send 'queue-failure))))
