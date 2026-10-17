(defpackage #:darterfly/wifi
  (:use #:cl)
  (:import-from #:darterfly/crypto #:octets #:hmac-sha1 #:pbkdf2-sha1 #:prf-sha1 #:aes-unwrap #:random-octets)
  (:export #:passphrase-pmk #:+rsn-psk-ccmp+ #:make-supplicant #:supplicant-receive
           #:supplicant-ptk #:supplicant-tk #:supplicant-gtk #:supplicant-gtk-index #:supplicant-state
           #:+eapol-ethertype+ #:network-status))
(in-package #:darterfly/wifi)

(defconstant +eapol-ethertype+ #x888E)

(defparameter +rsn-psk-ccmp+
  (octets #x30 20 1 0 0 #x0F #xAC 4 1 0 0 #x0F #xAC 4 1 0 0 #x0F #xAC 2 0 0))

(defun passphrase-pmk (passphrase ssid)
  (pbkdf2-sha1 passphrase ssid 4096 32))

(defconstant +key-version+ 2)
(defconstant +key-pairwise+ (ash 1 3))
(defconstant +key-install+ (ash 1 6))
(defconstant +key-ack+ (ash 1 7))
(defconstant +key-mic+ (ash 1 8))
(defconstant +key-secure+ (ash 1 9))
(defconstant +key-encrypted+ (ash 1 12))

(defstruct supplicant
  pmk own peer (rsn-ie +rsn-psk-ccmp+) (state :idle)
  snonce anonce ptk replay gtk gtk-index gtk-rsc)

(defun supplicant-tk (s) (and (supplicant-ptk s) (subseq (supplicant-ptk s) 32 48)))
(defun kck (s) (subseq (supplicant-ptk s) 0 16))
(defun kek (s) (subseq (supplicant-ptk s) 16 32))

(defun u16be (v i) (logior (ash (aref v i) 8) (aref v (1+ i))))
(defun be (n bytes) (loop for i from (1- bytes) downto 0 collect (ldb (byte 8 (* 8 i)) n)))

(defun octets< (a b)
  (loop for x across a for y across b
        unless (= x y) return (< x y)))

(defun derive-ptk (pmk aa spa anonce snonce)
  (multiple-value-bind (mac-lo mac-hi) (if (octets< aa spa) (values aa spa) (values spa aa))
    (multiple-value-bind (nonce-lo nonce-hi) (if (octets< anonce snonce) (values anonce snonce) (values snonce anonce))
      (prf-sha1 pmk "Pairwise key expansion" (octets mac-lo mac-hi nonce-lo nonce-hi) 384))))

(defstruct key-frame version info length replay nonce iv rsc mic data raw)

(defun parse-key-frame (frame)
  (let ((frame (octets frame)))
    (when (and (>= (length frame) 99) (= 3 (aref frame 1)) (= 2 (aref frame 4)))
      (let ((data-length (u16be frame 97))
            (total (+ 4 (u16be frame 2))))
        (when (<= (+ 99 data-length) total (length frame))
          (setf frame (subseq frame 0 total))
          (make-key-frame :version (aref frame 0) :info (u16be frame 5) :length (u16be frame 7)
                          :replay (subseq frame 9 17) :nonce (subseq frame 17 49) :iv (subseq frame 49 65)
                          :rsc (subseq frame 65 73) :mic (subseq frame 81 97)
                          :data (subseq frame 99 (+ 99 data-length)) :raw frame))))))

(defun key-mic (kck frame)
  (let ((copy (copy-seq frame)))
    (fill copy 0 :start 81 :end 97)
    (subseq (hmac-sha1 kck copy) 0 16)))

(defun key-frame (s info replay &key (nonce (make-array 32 :initial-element 0)) (data #()))
  (let ((frame (octets 1 3 (be (+ 95 (length data)) 2) 2 (be info 2) 0 0 replay nonce
                       (make-array 16 :initial-element 0) (make-array 8 :initial-element 0)
                       (make-array 8 :initial-element 0) (make-array 16 :initial-element 0)
                       (be (length data) 2) data)))
    (when (logtest info +key-mic+)
      (replace frame (key-mic (kck s) frame) :start1 81))
    frame))

(defun elements (data)
  (loop with at = 0
        while (< (+ at 1) (length data))
        for type = (aref data at)
        for len = (aref data (1+ at))
        until (or (and (= type #xDD) (zerop len)) (> (+ at 2 len) (length data)))
        collect (cons type (subseq data (+ at 2) (+ at 2 len)))
        do (incf at (+ 2 len))))

(defun gtk-element (elements)
  (loop for (type . body) in elements
        when (and (= type #xDD) (>= (length body) 6)
                  (equalp (subseq body 0 4) #(0 #x0F #xAC 1)))
          return (values (subseq body 6) (ldb (byte 2 0) (aref body 4)))))

(defun rsn-element (elements)
  (loop for (type . body) in elements
        when (= type #x30) return (octets type (length body) body)))

(defun fresh-replay-p (s frame)
  (or (null (supplicant-replay s)) (octets< (supplicant-replay s) (key-frame-replay frame))))

(defun mic-valid-p (s frame)
  (equalp (key-frame-mic frame) (key-mic (kck s) (key-frame-raw frame))))

(defun take-gtk (s frame)
  (let ((plain (aes-unwrap (kek s) (key-frame-data frame))))
    (when plain
      (let ((elements (elements plain)))
        (multiple-value-bind (gtk index) (gtk-element elements)
          (when gtk
            (setf (supplicant-gtk s) gtk (supplicant-gtk-index s) index
                  (supplicant-gtk-rsc s) (key-frame-rsc frame))
            elements))))))

(defun supplicant-receive (s frame)
  (let ((k (parse-key-frame frame)))
    (when (and k (= +key-version+ (ldb (byte 3 0) (key-frame-info k))) (logtest +key-ack+ (key-frame-info k))
               (fresh-replay-p s k))
      (let ((info (key-frame-info k)))
        (cond ((and (logtest info +key-pairwise+) (not (logtest info +key-mic+)))
               (let ((snonce (if (equalp (key-frame-nonce k) (supplicant-anonce s))
                                 (supplicant-snonce s)
                                 (random-octets 32))))
                 (setf (supplicant-anonce s) (key-frame-nonce k)
                       (supplicant-snonce s) snonce
                       (supplicant-ptk s) (derive-ptk (supplicant-pmk s) (supplicant-peer s) (supplicant-own s)
                                                      (key-frame-nonce k) snonce)
                       (supplicant-state s) :sent-2)
                 (values (key-frame s (logior +key-version+ +key-pairwise+ +key-mic+) (key-frame-replay k)
                                    :nonce snonce :data (supplicant-rsn-ie s))
                         nil)))
              ((and (logtest info +key-pairwise+) (logtest info +key-mic+) (logtest info +key-install+)
                    (logtest info +key-encrypted+) (supplicant-ptk s)
                    (equalp (key-frame-nonce k) (supplicant-anonce s))
                    (mic-valid-p s k))
               (let ((elements (take-gtk s k)))
                 (when elements
                   (setf (supplicant-replay s) (key-frame-replay k)
                         (supplicant-state s) :keyed)
                   (values (key-frame s (logior +key-version+ +key-pairwise+ +key-mic+ +key-secure+) (key-frame-replay k))
                           (list (list :pairwise (supplicant-tk s))
                                 (list :group (supplicant-gtk s) (supplicant-gtk-index s) (supplicant-gtk-rsc s))
                                 (list :ap-rsn (rsn-element elements)))))))
              ((and (not (logtest info +key-pairwise+)) (logtest info +key-mic+) (logtest info +key-secure+)
                    (logtest info +key-encrypted+) (eq (supplicant-state s) :keyed)
                    (mic-valid-p s k) (take-gtk s k))
               (setf (supplicant-replay s) (key-frame-replay k))
               (values (key-frame s (logior +key-version+ +key-mic+ +key-secure+) (key-frame-replay k))
                       (list (list :group (supplicant-gtk s) (supplicant-gtk-index s) (supplicant-gtk-rsc s))))))))))
