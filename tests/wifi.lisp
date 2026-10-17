(in-package #:darterfly/test)

(def-suite wifi :in all)
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
