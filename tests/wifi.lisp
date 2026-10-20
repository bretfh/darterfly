(in-package #:darterfly/test)

(def-suite wifi :in host)
(in-suite wifi)

(defun hex (string)
  (let ((string (remove #\Space string)))
    (coerce (loop for i from 0 below (length string) by 2
                  collect (parse-integer string :start i :end (+ i 2) :radix 16))
            '(simple-array (unsigned-byte 8) (*)))))

(test sha1-matches-the-published-digests
  (is (equalp (hex "a9993e364706816aba3e25717850c26c9cd0d89d") (darterfly/crypto:sha1 "abc")))
  (is (equalp (hex "da39a3ee5e6b4b0d3255bfef95601890afd80709") (darterfly/crypto:sha1 "")))
  (is (equalp (hex "84983e441c3bd26ebaae4aa1f95129e5e54670f1")
              (darterfly/crypto:sha1 "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq")))
  (is (equalp (hex "34aa973cd4c4daa4f61eeb2bdbad27316534016f")
              (darterfly/crypto:sha1 (make-string 1000000 :initial-element #\a)))))

(test hmac-sha1-matches-rfc-2202
  (is (equalp (hex "b617318655057264e28bc0b6fb378c8ef146be00")
              (darterfly/crypto:hmac-sha1 (make-array 20 :initial-element #x0b) "Hi There")))
  (is (equalp (hex "effcdf6ae5eb2fa2d27416d5f184df9c259a7c79")
              (darterfly/crypto:hmac-sha1 "Jefe" "what do ya want for nothing?")))
  (is (equalp (hex "aa4ae5e15272d00e95705637ce8a3b55ed402112")
              (darterfly/crypto:hmac-sha1 (make-array 80 :initial-element #xaa)
                                          "Test Using Larger Than Block-Size Key - Hash Key First"))))

(test pbkdf2-matches-rfc-6070-and-the-wpa-passphrase-vectors
  (is (equalp (hex "0c60c80f961f0e71f3a9b524af6012062fe037a6") (darterfly/crypto:pbkdf2-sha1 "password" "salt" 1 20)))
  (is (equalp (hex "4b007901b765489abead49d926f721d065a429c1") (darterfly/crypto:pbkdf2-sha1 "password" "salt" 4096 20)))
  (is (equalp (hex "f42c6fc52df0ebef9ebb4b90b38a5f902e83fe1b135a70e23aed762e9710a12e")
              (darterfly/wifi:passphrase-pmk "password" "IEEE")))
  (is (equalp (hex "0dc0d6eb90555ed6419756b9a15ec3e3209b63df707dd508d14581f8982721af")
              (darterfly/wifi:passphrase-pmk "ThisIsAPassword" "ThisIsASSID"))))

(test prf-matches-the-802.11-vector
  (is (equalp (hex "bcd4c650b30b9684951829e0d75f9d54b862175ed9f00606")
              (darterfly/crypto:prf-sha1 (make-array 20 :initial-element #x0b) "prefix" "Hi There" 192))))

(test aes-matches-fips-197
  (let ((plain (hex "00112233445566778899aabbccddeeff")))
    (loop for (key cipher) in '(("000102030405060708090a0b0c0d0e0f" "69c4e0d86a7b0430d8cdb78070b4c55a")
                                ("000102030405060708090a0b0c0d0e0f1011121314151617" "dda97ca4864cdfe06eaf70a0ec0d7191")
                                ("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f" "8ea2b7ca516745bfeafc49904b496089"))
          do (let ((k (darterfly/crypto:aes-key (hex key))))
               (is (equalp (hex cipher) (darterfly/crypto:aes-encrypt-block k plain)))
               (is (equalp plain (darterfly/crypto:aes-decrypt-block k (hex cipher))))))))

(test aes-key-wrap-matches-rfc-3394
  (let ((kek (hex "000102030405060708090a0b0c0d0e0f"))
        (key (hex "00112233445566778899aabbccddeeff"))
        (wrapped (hex "1fa68b0a8112b447aef34bd8fb5a7b829d3e862371d2cfe5")))
    (is (equalp wrapped (darterfly/crypto:aes-wrap kek key)))
    (is (equalp key (darterfly/crypto:aes-unwrap kek wrapped)))
    (let ((tampered (copy-seq wrapped)))
      (setf (aref tampered 3) (logxor 1 (aref tampered 3)))
      (is (null (darterfly/crypto:aes-unwrap kek tampered))))))

(defparameter +ap-mac+ (hex "04f021323f38"))
(defparameter +our-mac+ (hex "021122334455"))

(defun authenticator-frame (ptk info replay nonce &optional (data #()))
  (let ((a (darterfly/wifi::make-supplicant :ptk ptk)))
    (darterfly/wifi::key-frame a info (hex replay) :nonce nonce :data data)))

(defun wrapped-gtk (ptk gtk index)
  (let* ((plain (darterfly/crypto:octets darterfly/wifi:+rsn-psk-ccmp+ #xDD (+ 6 (length gtk)) 0 #x0F #xAC 1 index 0 gtk))
         (padded (darterfly/crypto:octets plain (if (zerop (mod (length plain) 8)) #() #xDD)
                                          (make-array (mod (- 7 (mod (length plain) 8)) 8) :initial-element 0))))
    (darterfly/crypto:aes-wrap (subseq ptk 16 32) padded)))

(defun mic-holds-p (ptk frame)
  (let ((k (darterfly/wifi::parse-key-frame frame)))
    (equalp (darterfly/wifi::key-frame-mic k) (darterfly/wifi::key-mic (subseq ptk 0 16) (darterfly/wifi::key-frame-raw k)))))

(test the-four-way-handshake-installs-the-pairwise-and-group-keys
  (let* ((pmk (darterfly/wifi:passphrase-pmk "correct horse battery" "Turris"))
         (s (darterfly/wifi:make-supplicant :pmk pmk :own +our-mac+ :peer +ap-mac+))
         (anonce (darterfly/crypto:random-octets 32))
         (gtk (darterfly/crypto:random-octets 16)))
    (multiple-value-bind (m2 events) (darterfly/wifi:supplicant-receive s (authenticator-frame nil #x008a "0000000000000001" anonce))
      (is (null events))
      (let* ((k2 (darterfly/wifi::parse-key-frame m2))
             (ptk (darterfly/wifi::derive-ptk pmk +ap-mac+ +our-mac+ anonce (darterfly/wifi::key-frame-nonce k2))))
        (is (= #x010a (darterfly/wifi::key-frame-info k2)))
        (is (mic-holds-p ptk m2))
        (is (equalp darterfly/wifi:+rsn-psk-ccmp+ (darterfly/wifi::key-frame-data k2)))
        (multiple-value-bind (m4 events)
            (darterfly/wifi:supplicant-receive s (authenticator-frame ptk #x13ca "0000000000000002" anonce (wrapped-gtk ptk gtk 1)))
          (is (= #x030a (darterfly/wifi::key-frame-info (darterfly/wifi::parse-key-frame m4))))
          (is (mic-holds-p ptk m4))
          (is (equalp (subseq ptk 32 48) (second (assoc :pairwise events))))
          (is (equalp gtk (second (assoc :group events))))
          (is (= 1 (third (assoc :group events))))
          (is (equalp darterfly/wifi:+rsn-psk-ccmp+ (second (assoc :ap-rsn events))))
          (is (eq :keyed (darterfly/wifi:supplicant-state s))))
        (is (null (darterfly/wifi:supplicant-receive s (authenticator-frame ptk #x13ca "0000000000000002" anonce (wrapped-gtk ptk gtk 1)))))
        (let ((new-gtk (darterfly/crypto:random-octets 16)))
          (multiple-value-bind (reply events)
              (darterfly/wifi:supplicant-receive s (authenticator-frame ptk #x1382 "0000000000000003" (make-array 32 :initial-element 0) (wrapped-gtk ptk new-gtk 2)))
            (is (= #x0302 (darterfly/wifi::key-frame-info (darterfly/wifi::parse-key-frame reply))))
            (is (mic-holds-p ptk reply))
            (is (equalp new-gtk (second (assoc :group events))))
            (is (= 2 (third (assoc :group events))))))))))

(test a-message-3-with-a-bad-mic-is-ignored
  (let* ((pmk (darterfly/wifi:passphrase-pmk "correct horse battery" "Turris"))
         (s (darterfly/wifi:make-supplicant :pmk pmk :own +our-mac+ :peer +ap-mac+))
         (anonce (darterfly/crypto:random-octets 32))
         (m2 (darterfly/wifi:supplicant-receive s (authenticator-frame nil #x008a "0000000000000001" anonce)))
         (wrong (darterfly/wifi::derive-ptk (darterfly/wifi:passphrase-pmk "wrong" "Turris") +ap-mac+ +our-mac+ anonce
                                           (darterfly/wifi::key-frame-nonce (darterfly/wifi::parse-key-frame m2)))))
    (is (null (darterfly/wifi:supplicant-receive s (authenticator-frame wrong #x13ca "0000000000000002" anonce
                                                                        (wrapped-gtk wrong (darterfly/crypto:random-octets 16) 1)))))
    (is (eq :sent-2 (darterfly/wifi:supplicant-state s)))))

(defun tlv (type data)
  (let ((data (darterfly/crypto:octets data)))
    (darterfly/crypto:octets (le32 type) (le32 (length data)) data (make-array (mod (- (length data)) 4) :initial-element 0))))

(defun le32 (n) (loop for i below 4 collect (ldb (byte 8 (* 8 i)) n)))

(test the-firmware-file-splits-into-its-images
  (let* ((file (darterfly/crypto:octets (le32 0) (le32 #x0A4C5749) (make-array 64 :initial-element 0) (make-array 16 :initial-element 0)
                                        (tlv 19 (darterfly/crypto:octets (le32 #x440000) #(1 2 3)))
                                        (tlv 19 (darterfly/crypto:octets (le32 #xFFFFCCCC)))
                                        (tlv 19 (darterfly/crypto:octets (le32 #x800000) #(4 5 6 7)))
                                        (tlv 19 (darterfly/crypto:octets (le32 #xAAAABBBB)))
                                        (tlv 19 (darterfly/crypto:octets (le32 0) #(8)))
                                        (tlv 52 #(9 9 9 9 9))
                                        (tlv 48 #(1 0 3 0 2 5 6 7))
                                        (tlv 30 (darterfly/crypto:octets (le32 1) (le32 4)))))
         (fw (darterfly/wifi::parse-firmware file))
         (images (darterfly/wifi::firmware-images fw)))
    (is (equalp '((#x440000 . #(1 2 3))) (mapcar (lambda (s) (cons (car s) (coerce (cdr s) 'simple-vector))) (getf images :lmac))))
    (is (equalp '(#(4 5 6 7)) (mapcar (lambda (s) (coerce (cdr s) 'simple-vector)) (getf images :umac))))
    (is (equalp '(#(8)) (mapcar (lambda (s) (coerce (cdr s) 'simple-vector)) (getf images :paging))))
    (is (equalp #(9 9 9 9 9) (coerce (darterfly/wifi::firmware-iml fw) 'simple-vector)))
    (is (= 3 (darterfly/wifi::command-version fw 0 1)))
    (is (= 6 (darterfly/wifi::command-version fw 5 2)))
    (is (logbitp 34 (darterfly/wifi::firmware-capabilities fw)))))

(defun offline-link ()
  (let ((card (make-instance 'darterfly/wifi::wireless-card)))
    (setf (darterfly/wifi::card-nvm card) (list :mac (hex "10f60a82a3ca")))
    (make-instance 'darterfly/wifi::link :card card :bssid (hex "04f021323f38")
                                         :bss (list :channel 153 :interval 100 :dtim 2 :tsf #x0102030405060708 :gp2 77))))

(test join-commands-have-the-firmware-layouts
  (let ((l (offline-link)))
    (is (= 148 (length (darterfly/wifi::mac-context l :add nil))))
    (let ((m (darterfly/wifi::mac-context l :modify t)))
      (is (equalp (hex "10f60a82a3ca") (subseq m 16 22)))
      (is (equalp (hex "04f021323f38") (subseq m 24 30)))
      (is (= 1 (darterfly/wifi::u32le m 100)))
      (is (= 200 (darterfly/wifi::u32le m 124))))
    (is (= 1940 (length (darterfly/wifi::scan-request (darterfly/wifi::link-card l)))))
    (is (= 24 (length (darterfly/wifi::frame-header #xB0 0 (hex "04f021323f38") (hex "10f60a82a3ca") (hex "04f021323f38") 5))))))

(test an-eapol-frame-comes-back-out-of-a-data-frame
  (let* ((l (offline-link))
         (frame (darterfly/wifi::eapol-frame l (darterfly/crypto:octets 1 3 0 5 2 0 0 0 0))))
    (is (= 8 (aref frame 0)))
    (is (= 1 (aref frame 1)))
    (setf (aref frame 1) 2)
    (multiple-value-bind (type body) (darterfly/wifi::data-payload frame)
      (is (= #x888E type))
      (is (equalp #(1 3 0 5 2 0 0 0 0) (coerce body 'simple-vector))))))

(test a-padded-qos-frame-loses-its-padding
  (let* ((frame (darterfly/crypto:octets #x88 2 0 0 (make-array 22 :initial-element 7) #xEE #xEE #xAA #xAA 3 0 0 0 8 0 1 2))
         (payload (darterfly/crypto:octets (le16 (length frame)) 0 #x20 (make-array 8 :initial-element 0) 3 0 0 0 (make-array 48 :initial-element 0) frame)))
    (multiple-value-bind (type body) (darterfly/wifi::data-payload (darterfly/wifi::mpdu payload))
      (is (= #x0800 type))
      (is (equalp #(1 2) (coerce body 'simple-vector))))))

(defun le16 (n) (list (ldb (byte 8 0) n) (ldb (byte 8 8) n)))

(test losing-the-access-point-is-noticed
  (let* ((l (offline-link))
         (bssid (hex "04f021323f38")) (me (hex "10f60a82a3ca"))
         (deauth (darterfly/crypto:octets (darterfly/wifi::frame-header #xC0 0 me bssid bssid 1) 7 0))
         (other (darterfly/crypto:octets (darterfly/wifi::frame-header #xC0 0 me (hex "020000000001") (hex "020000000001") 1) 7 0))
         (beacons (lambda (n) (list :code #xA2 :payload (darterfly/crypto:octets (le32 0) (le32 n) (le32 n) (le32 0) (le32 0))))))
    (is (eq :deauthenticated (darterfly/wifi::lost-signal l (list :code #xC1) deauth)))
    (is (null (darterfly/wifi::lost-signal l (list :code #xC1) other)))
    (is (eq :beacons-lost (darterfly/wifi::lost-signal l (funcall beacons 30) nil)))
    (is (null (darterfly/wifi::lost-signal l (funcall beacons 3) nil)))))

(test the-power-table-is-the-size-the-firmware-checks
  (let ((sent nil))
    (sb-int:encapsulate 'darterfly/wifi::command-ok 'capture
                        (lambda (f w group opcode payload) (declare (ignore f w)) (push (list group opcode (length payload)) sent) nil))
    (unwind-protect (darterfly/wifi::set-power-save (offline-link) 2)
      (sb-int:unencapsulate 'darterfly/wifi::command-ok 'capture))
    (is (equal '((0 #x77 4) (0 #xA9 40)) (reverse sent)))))

(test health-checks-the-wireless-interface
  (let* ((l (offline-link))
         (d (make-instance 'darterfly/wifi::wireless-interface :link l))
         (darterfly/wifi::*card* (darterfly/wifi::link-card l))
         (darterfly/wifi::*link* l)
         (darterfly/net:*interface* (darterfly/net::make-interface :device d))
         (probe (second (assoc :wifi darterfly/health:*checks*))))
    (setf (darterfly/wifi::link-keyed l) t)
    (is (eq :ok (first (funcall probe))))
    (is (null (getf (rest (funcall probe)) :rejoining)))
    (setf (darterfly/wifi::wireless-rejoining d) :beacons-lost)
    (is (eq :fail (first (funcall probe))))
    (is (eq :beacons-lost (getf (rest (funcall probe)) :rejoining)))))

(test wired-health-does-not-fail-for-a-retained-wifi-card
  (let* ((darterfly/wifi::*card* (darterfly/wifi::link-card (offline-link)))
         (darterfly/net:*interface*
           (darterfly/net::make-interface :device (make-instance 'darterfly/devices:ethernet-controller)))
         (probe (second (assoc :wifi darterfly/health:*checks*))))
    (is (equal '(:off :because :cable) (funcall probe)))))

(test replacing-a-block-ack-session-removes-it-before-allocating-again
  (let* ((l (offline-link)) (sent nil) (fail-remove nil)
         (request (darterfly/crypto:octets
                   (darterfly/wifi::frame-header #xD0 0 (hex "10f60a82a3ca") (hex "04f021323f38") (hex "04f021323f38") 0)
                   3 0 7 (darterfly/wifi::le-u16 (logior 2 (ash 5 2) (ash 64 6)))
                   0 0 0 0)))
    (setf (darterfly/wifi::card-firmware (darterfly/wifi::link-card l))
          (darterfly/wifi::make-firmware :commands '((5 #x16 2 1))))
    (sb-int:encapsulate 'darterfly/wifi::command-ok 'capture-ba
      (lambda (f w group opcode payload)
        (declare (ignore f w group opcode))
        (push payload sent)
        (when (and fail-remove (= 2 (darterfly/wifi::u32le payload 0))) (error "removal refused"))
        (list :payload (darterfly/crypto:octets (le32 3)))))
    (sb-int:encapsulate 'darterfly/wifi::transmit 'capture-ba
      (lambda (f l frame &rest options) (declare (ignore f l frame options)) nil))
    (unwind-protect
         (progn
           (darterfly/wifi::answer-addba l request)
           (darterfly/wifi::answer-addba l request)
           (is (equal '(0 2 0) (mapcar (lambda (p) (darterfly/wifi::u32le p 0)) (reverse sent))))
           (is (every (lambda (p) (= 16 (length p))) sent))
           (is (equal '((5 . 3)) (darterfly/wifi::link-block-acks l)))
           (setf fail-remove t sent nil)
           (is (null (getf (darterfly/wifi::answer-addba l request) :baid)))
           (is (= 1 (length sent)) "failed removal must not be followed by allocation")
           (is (equal '((5 . 3)) (darterfly/wifi::link-block-acks l)))
           (setf fail-remove nil sent nil)
           (let ((delba (darterfly/crypto:octets (subseq request 0 24) 3 2
                          (darterfly/wifi::le-u16 (logior (ash 5 12) (ash 1 11))) 0 0)))
             (darterfly/wifi::end-block-ack l delba)
             (is (null (darterfly/wifi::link-block-acks l)))
             (is (= 5 (darterfly/wifi::u32le (first sent) 8))))
           (setf (darterfly/wifi::firmware-commands (darterfly/wifi::card-firmware (darterfly/wifi::link-card l))) '((5 #x16 1 1))
                 (darterfly/wifi::link-block-acks l) '((5 . 3)) sent nil)
           (darterfly/wifi::remove-block-ack l 5)
           (is (= 16 (length (first sent))))
           (is (= 3 (darterfly/wifi::u32le (first sent) 4)))
           (is (null (darterfly/wifi::block-ack-action l (subseq request 0 27)))))
      (sb-int:unencapsulate 'darterfly/wifi::command-ok 'capture-ba)
      (sb-int:unencapsulate 'darterfly/wifi::transmit 'capture-ba))))

(test a-failed-rejoin-does-not-resurrect-the-old-link
  (let* ((l (offline-link))
         (d (make-instance 'darterfly/wifi::wireless-interface :link l))
         (darterfly/net:*interface* (darterfly/net::make-interface :device d)))
    (setf (darterfly/wifi::link-keyed l) t)
    (sb-int:encapsulate 'darterfly/wifi::rejoin 'failed-rejoin
      (lambda (f device) (declare (ignore f device)) nil))
    (unwind-protect
         (progn
           (sb-thread:join-thread (darterfly/wifi::lost d :firmware-error))
           (is (null (darterfly/wifi::wireless-up-p d)))
           (is (null (getf (darterfly/wifi:network-status) :up)))
           (is (null (darterfly/wifi::link-keyed l))))
      (sb-int:unencapsulate 'darterfly/wifi::rejoin 'failed-rejoin))))

(test queued-block-ack-work-cannot-touch-a-retired-link
  (let* ((l (offline-link))
         (d (make-instance 'darterfly/wifi::wireless-interface :link l))
         (calls nil)
         (request (darterfly/crypto:octets
                   (darterfly/wifi::frame-header #xD0 0 (hex "10f60a82a3ca") (hex "04f021323f38") (hex "04f021323f38") 0)
                   3 0 7 (darterfly/wifi::le-u16 (logior 2 (ash 5 2) (ash 64 6))) 0 0 0 0)))
    (setf (darterfly/wifi::link-keyed l) t
          (darterfly/wifi::link-block-acks l) '((5 . 3))
          (darterfly/wifi::card-firmware (darterfly/wifi::link-card l))
          (darterfly/wifi::make-firmware :commands '((5 #x16 2 1))))
    (sb-int:encapsulate 'darterfly/wifi::rejoin 'retired-link
      (lambda (f device) (declare (ignore f device)) nil))
    (sb-int:encapsulate 'darterfly/wifi::command-ok 'retired-link
      (lambda (&rest args) (declare (ignore args)) (push :command calls)
        (list :payload (darterfly/crypto:octets (le32 3)))))
    (sb-int:encapsulate 'darterfly/wifi::transmit 'retired-link
      (lambda (&rest args) (declare (ignore args)) (push :transmit calls)))
    (unwind-protect
         (progn
           ;; These callbacks were queued by the receive thread before loss,
           ;; but only get to run after reset has retired their firmware state.
           (sb-thread:join-thread (darterfly/wifi::lost d :woke))
           (darterfly/wifi::answer-addba l request)
           (darterfly/wifi::end-block-ack l
             (darterfly/crypto:octets (subseq request 0 24) 3 2
               (darterfly/wifi::le-u16 (logior (ash 5 12) (ash 1 11))) 0 0))
           (is (null calls)))
      (dolist (name '(darterfly/wifi::rejoin darterfly/wifi::command-ok darterfly/wifi::transmit))
        (sb-int:unencapsulate name 'retired-link)))))

(test old-receive-errors-do-not-retire-the-replacement-link
  (let* ((old (offline-link)) (new (offline-link))
         (d (make-instance 'darterfly/wifi::wireless-interface :link new)))
    (setf (darterfly/wifi::link-keyed new) t)
    (is (null (darterfly/wifi::lost d :firmware-error old)))
    (is (darterfly/wifi::wireless-up-p d))))

(test radio-transition-history-survives-reset-and-is-bounded
  (let ((card (darterfly/wifi::link-card (offline-link))))
    (dotimes (i 70) (darterfly/wifi::note card :lost i))
    (setf (darterfly/wifi::card-log card) nil)
    (darterfly/wifi::note card :reset)
    (is (= 64 (length (darterfly/wifi::card-history card))))
    (is (equal '(:reset) (getf (first (darterfly/wifi::card-history card)) :event)))
    (is (equal '(:lost 69) (getf (second (darterfly/wifi::card-history card)) :event)))))

(test waking-on-ethernet-invalidates-the-retained-radio-link
  (let* ((l (offline-link))
         (darterfly/wifi::*link* l)
         (darterfly/net:*interface*
           (darterfly/net::make-interface :device (make-instance 'darterfly/devices:ethernet-controller))))
    (setf (darterfly/wifi::link-keyed l) t)
    (darterfly/wifi::wifi-woke :woke nil)
    (is (null (darterfly/wifi::link-keyed l)))))

(test usb-notifications-do-not-read-a-suspended-filesystem
  (let* ((darterfly/net:*interface* (darterfly/net::make-interface))
         (device (make-instance 'darterfly/devices:ethernet-controller))
         (reads 0))
    ;; USB emits these notifications while holding controller/suspend locks.
    ;; Filesystem access here can wait for a disk that this same thread must wake.
    (sb-int:encapsulate 'probe-file 'suspended-fs
      (lambda (&rest args) (declare (ignore args))
        (incf reads) (error "filesystem is waiting for its suspended disk")))
    (sb-int:encapsulate 'sb-thread:make-thread 'suspended-fs
      (lambda (&rest args) (declare (ignore args)) :queued))
    (unwind-protect
         (dolist (event '(:added :removed))
           (is (eq :returned
                   (handler-case
                       (progn (darterfly/wifi::wifi-device-changed event device) :returned)
                     (error () :blocked))))
           (is (zerop reads)))
      (sb-int:unencapsulate 'probe-file 'suspended-fs)
      (sb-int:unencapsulate 'sb-thread:make-thread 'suspended-fs))))

(test a-recovered-radio-retries-an-expired-address-attempt
  (let* ((old (offline-link)) (new (offline-link))
         (d (make-instance 'darterfly/wifi::wireless-interface :link old))
         (darterfly/net:*interface* (darterfly/net::make-interface :device d))
         (calls 0) (sent-while-rejoining nil))
    (setf (darterfly/wifi::link-keyed old) t (darterfly/wifi::link-keyed new) t)
    ;; SBCL workers do not inherit the fixture's dynamic interface binding.
    (sb-int:encapsulate 'sb-thread:make-thread 'address-retry
      (lambda (f thunk &rest args)
        (let ((interface darterfly/net:*interface*))
          (apply f (lambda ()
                     (let ((darterfly/net:*interface* interface)
                           (darterfly/net::*configuration* nil))
                       (funcall thunk))) args))))
    (sb-int:encapsulate 'darterfly/wifi::rejoin 'address-retry
      (lambda (f device) (declare (ignore f))
        ;; The prior DHCP attempt expired while radio recovery was in progress.
        (setf (darterfly/wifi::wireless-link device) new) t))
    (sb-int:encapsulate 'darterfly/net:dhcp 'address-retry
      (lambda (&rest args) (declare (ignore args))
        (incf calls)
        (setf sent-while-rejoining (not (null (darterfly/wifi::wireless-rejoining d)))
              (darterfly/net::interface-ip darterfly/net:*interface*) (darterfly/net:ip-address "10.0.2.15"))))
    (unwind-protect
         (progn
           (sb-thread:join-thread (darterfly/wifi::lost d :firmware-error))
           (is (= 1 calls) "successful radio recovery retries an unconfigured selected interface")
           (is (plusp (darterfly/net::interface-ip darterfly/net:*interface*)))
           (is (null sent-while-rejoining) "clear rejoining before DHCP can transmit"))
      (dolist (name '(darterfly/wifi::rejoin darterfly/net:dhcp sb-thread:make-thread))
        (sb-int:unencapsulate name 'address-retry)))))

(test tx-completion-progress-is-bounded-by-published-descriptors
  (let* ((w (make-instance 'darterfly/wifi::wireless-card))
         (state (darterfly/wifi::make-wifi-tx-state :read 65530 :write 4))
         (p (make-array 48 :element-type '(unsigned-byte 8) :initial-element 0)))
    (setf (gethash 2 (darterfly/wifi::card-tx-queues w)) state
          (aref p 0) 1 (aref p 36) 2 (aref p 44) 2)
    (darterfly/wifi::wifi-tx-notification w (list :code 28 :payload p))
    (is (= 8 (darterfly/wifi::wifi-tx-state-completed state)))
    (is (= 2 (darterfly/wifi::wifi-tx-pending state)))
    (darterfly/wifi::wifi-tx-notification w (list :code 28 :payload p))
    (is (= 8 (darterfly/wifi::wifi-tx-state-completed state)) "duplicate completion cannot release more DMA")
    (setf (aref p 44) 5)
    (darterfly/wifi::wifi-tx-notification w (list :code 28 :payload p))
    (is (= 2 (darterfly/wifi::wifi-tx-pending state)))
    (is (= 1 (darterfly/wifi::wifi-tx-state-invalid state)))
    (dotimes (length 48)
      (finishes (darterfly/wifi::wifi-tx-notification w (list :code 28 :payload (subseq p 0 length)))))
    (is (= 2 (darterfly/wifi::wifi-tx-pending state)))
    (setf (aref p 44) 4)
    (darterfly/wifi::wifi-tx-notification w (list :code 28 :payload p))
    (is (zerop (darterfly/wifi::wifi-tx-pending state)))))

(test compressed-block-ack-completions-validate-the-entire-record-array
  (let* ((w (make-instance 'darterfly/wifi::wireless-card))
         (state (darterfly/wifi::make-wifi-tx-state :read 1 :write 20))
         (p (make-array 40 :element-type '(unsigned-byte 8) :initial-element 0)))
    (setf (gethash 2 (darterfly/wifi::card-tx-queues w)) state
          (aref p 28) 2 (aref p 32) 2 (aref p 34) 20)
    (darterfly/wifi::wifi-tx-notification w (list :code 197 :payload p))
    (is (= 19 (darterfly/wifi::wifi-tx-pending state)))
    (setf (aref p 28) 1)
    (darterfly/wifi::wifi-tx-notification w (list :code 197 :payload p))
    (is (zerop (darterfly/wifi::wifi-tx-pending state)))))

(test a-full-wifi-transmit-ring-never-reuses-a-live-buffer
  (let* ((w (make-instance 'darterfly/wifi::wireless-card))
         (q (darterfly/wifi::make-txq :qid 2))
         (l (make-instance 'darterfly/wifi::link :card w))
         (state (darterfly/wifi::make-wifi-tx-state :write 255)))
    (setf (darterfly/wifi::link-mgmt l) q (gethash 2 (darterfly/wifi::card-tx-queues w)) state)
    (sb-int:encapsulate 'darterfly/wifi::pump 'saturated-ring (lambda (&rest args) (declare (ignore args)) nil))
    (unwind-protect
         (progn
           ;; No DMA fields are initialized: touching one before capacity is
           ;; available would raise an unbound-slot/type error.
           (is (null (darterfly/wifi::transmit l #(0))))
           (is (= 255 (darterfly/wifi::wifi-tx-pending state)))
           (is (= 1 (darterfly/wifi::wifi-tx-state-backpressure state))))
      (sb-int:unencapsulate 'darterfly/wifi::pump 'saturated-ring))))
