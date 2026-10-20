(in-package #:darterfly/wifi)

(defparameter *wifi-settings* "/Library/Settings/wifi")

(defparameter *power-save* 2)

(defparameter *ht* t)

(defconstant +tx-slots+ 256)
(defconstant +mgmt-tid+ 15)

(defstruct txq
  ring byte-counts
  (commands (make-array +tx-slots+ :initial-element nil))
  (payloads (make-array +tx-slots+ :initial-element nil))
  (cur 0) (hw 0) (qid 1) (seq 0))

(defclass link ()
  ((card :initarg :card :reader link-card)
   (bss :initarg :bss :reader link-bss)
   (bssid :initarg :bssid :reader link-bssid)
   (mgmt :initform nil :accessor link-mgmt)
   (data :initform nil :accessor link-data)
   (seq :initform 0 :accessor link-seq)
   (aid :initform nil :accessor link-aid)
   (supplicant :initform nil :accessor link-supplicant)
   (keyed :initform nil :accessor link-keyed)
   (retired :initform nil :accessor link-retired)
   (want-ht :initarg :want-ht :initform nil :reader link-want-ht)
   (ht :initform nil :accessor link-ht)
   (signal :initform nil :accessor link-signal)
   (frames :initform nil :accessor link-frames)
   (block-acks :initform nil :accessor link-block-acks)
   (lock :initform (sb-thread:make-mutex :name "wifi link") :reader link-lock)))

(defun retire-link (l)
  ;; Drain in-flight link operations before resetting their firmware resources.
  ;; Queued callbacks keep L, so retirement is permanent even after a new join.
  (when l
    (sb-thread:with-recursive-lock ((link-lock l))
      (setf (link-retired l) t (link-keyed l) nil))))

(defun mac-octets (text)
  (apply #'octets (mapcar (lambda (h) (parse-integer h :radix 16)) (uiop:split-string text :separator ":"))))

(defun mpdu (payload)
  (when (and payload (>= (length payload) 64))
    (let* ((status (u32le payload 12))
           (len (logior (aref payload 0) (ash (aref payload 1) 8)))
           (raw (subseq payload 64 (min (length payload) (+ 64 len)))))
      (when (and (logtest status 1) (logtest status 2) (>= (length raw) 10))
        (let ((frame (if (logtest (aref payload 3) #x20)
                         (let ((h (header-length raw)))
                           (if (> (length raw) (+ h 2)) (octets (subseq raw 0 h) (subseq raw (+ h 2))) raw))
                         raw)))
          (values frame status (aref payload 42) (u32le payload 44)
                  (flet ((dbm (e) (if (zerop e) -256 (- e)))) (max (dbm (aref payload 40)) (dbm (aref payload 41))))))))))

(defun header-length (frame)
  (let ((type (ldb (byte 2 2) (aref frame 0)))
        (subtype (ldb (byte 4 4) (aref frame 0))))
    (if (and (= type 2) (logbitp 3 subtype)) 26 24)))

(defun frame-header (fc0 fc1 a1 a2 a3 seq)
  (octets fc0 fc1 0 0 a1 a2 a3 (ldb (byte 8 0) (ash seq 4)) (ldb (byte 8 8) (ash seq 4))))

(defun next-seq (l) (prog1 (link-seq l) (setf (link-seq l) (mod (1+ (link-seq l)) 4096))))

(defun add-queue (l tid)
  (let ((w (link-card l))
        (q (make-txq :ring (dma-pages (/ (* 256 +tx-slots+) +page+)) :byte-counts (dma-pages 1))))
    (let* ((p (getf (command-ok w 5 #x17 (octets (le-u32 0) (le-u32 1) tid 0 0 0 (le-u32 0)
                                                 (le-u32 (- (integer-length (1- +tx-slots+)) 3))
                                                 (le-u32 (ldb (byte 32 0) (txq-byte-counts q))) (le-u32 (ash (txq-byte-counts q) -32))
                                                 (le-u32 (ldb (byte 32 0) (txq-ring q))) (le-u32 (ash (txq-ring q) -32))))
                    :payload)))
      (setf (txq-qid q) (logior (aref p 0) (ash (aref p 1) 8))
            (txq-hw q) (logior (aref p 4) (ash (aref p 5) 8)))
      (note w :queue (txq-qid q) :tid tid :write-pointer (txq-hw q))
      q)))

(defun next-data-seq (q) (prog1 (txq-seq q) (setf (txq-seq q) (mod (1+ (txq-seq q)) 4096))))

(defun tx-rate (frame)
  (let ((data (= 2 (ldb (byte 2 2) (aref frame 0))))
        (group (logbitp 0 (aref frame 4))))
    (if (and data (not group))
        (values 0 0)
        (values (ash 1 0) (logior (ash 1 14) (ash 1 8))))))

(defun transmit (l frame &key (encrypt nil) (queue (link-mgmt l)))
  (sb-thread:with-recursive-lock ((link-lock l))
    (when (link-retired l) (return-from transmit nil))
    (let* ((w (link-card l))
           (q queue)
           (hdrlen (header-length frame))
           (pad (mod (- hdrlen) 4))
           (idx (txq-cur q))
           (cmd (or (aref (txq-commands q) idx) (setf (aref (txq-commands q) idx) (devices:vm-page-grab))))
           (body (or (aref (txq-payloads q) idx) (setf (aref (txq-payloads q) idx) (devices:vm-page-grab))))
           (tfd (+ (txq-ring q) (* 256 idx)))
           (payload (subseq frame hdrlen)))
      (when (> (length payload) +page+) (error "wifi frame too long: ~d bytes" (length frame)))
      (multiple-value-bind (rate-flags rate) (tx-rate frame)
        (let* ((flags (logior rate-flags (if encrypt 0 (ash 1 1))))
               (offload (logior (ash (logand (floor hdrlen 2) #x1F) 8) (if (plusp pad) (ash 1 13) 0)))
               (head (octets #x1C 0 idx (txq-qid q)
                             (le-u16 (length frame)) (le-u16 flags) (le-u32 offload) (zeros 8) (le-u32 rate) (zeros 8)
                             (subseq frame 0 hdrlen) (zeros pad))))
          (copy-to-dma head cmd)
          (copy-to-dma payload body)
          (copy-to-dma (zeros 256) tfd)
          (put-16 tfd 0 3)
          (put-16 tfd 2 20) (put-64 tfd 4 cmd)
          (put-16 tfd 12 (- (length head) 20)) (put-64 tfd 14 (+ cmd 20))
          (put-16 tfd 22 (length payload)) (put-64 tfd 24 body)
          (put-16 (txq-byte-counts q) (* 2 idx) (length frame))
          (setf (txq-cur q) (mod (1+ idx) +tx-slots+)
                (txq-hw q) (mod (1+ (txq-hw q)) 65536)
                (reg w #x460) (logior (ash (txq-qid q) 16) (txq-hw q)))
          idx)))))

(defun take-frame (l test seconds)
  (let ((w (link-card l))
        (deadline (+ (microseconds) (* seconds 1000000))))
    (loop
      (let ((found (find-if test (link-frames l))))
        (when found
          (setf (link-frames l) (remove found (link-frames l) :count 1))
          (return found)))
      (when (> (microseconds) deadline) (return nil))
      (let ((packets (pump w)))
        (dolist (p (take-mpdus w))
          (let ((frame (mpdu (getf p :payload))))
            (when frame (setf (link-frames l) (append (link-frames l) (list frame))))))
        (unless packets (sleep 0.002))))))

(defun from-bss-p (l frame fc0)
  (and (= (aref frame 0) fc0) (>= (length frame) 24)
       (equalp (subseq frame 10 16) (link-bssid l))))

(defun context-commands (l)
  (let* ((w (link-card l)) (bss (link-bss l)))
    (multiple-value-bind (tx rx) (valid-antennas w)
      (declare (ignore tx))
      (command-ok w 0 #x8 (octets (le-u32 0) (le-u32 1) (le-u32 (getf bss :channel)) (if (> (getf bss :channel) 14) 0 1) 0 0 0
                                  (le-u32 0) (le-u32 0) (le-u32 0) (le-u32 0)))
      (let ((chains (max 1 (logcount rx))))
        (command-ok w 5 #x8 (octets (le-u32 0) (le-u32 (logior (ash rx 1) (ash chains 10) (ash chains 12))) (le-u32 0) (zeros 16) 0 0 0 0))))
    (command-ok w 0 #x28 (mac-context l :add nil))
    (let ((p (getf (command-ok w 0 #x2B (octets (le-u32 0) (le-u32 1) (le-u32 0) (le-u32 #xFFFFFFFF) (le-u32 #xFFFFFFFF) (le-u32 0) (le-u32 0))) :payload)))
      (unless (zerop (u32le p 0)) (error "the AX210 refused the binding: ~x" (u32le p 0))))
    (add-station l nil)
    (setf (link-mgmt l) (add-queue l +mgmt-tid+))
    (command-ok w 3 5 (octets (le-u32 0) (le-u32 1) (le-u32 0) (le-u32 (* 9 (getf bss :interval 100))) (le-u32 0) (le-u32 0)))))

(defun station-flags (l)
  (let ((ht (link-ht l)))
    (if ht
        (values (logior (ash 1 28) (ash (getf ht :exponent) 19) (ash (getf ht :density) 23))
                (logior (ash 3 26) (ash 3 28) (ash #xF 19) (ash 7 23)))
        (values 0 (logior (ash 3 26) (ash 3 28))))))

(defun add-station (l modify)
  (multiple-value-bind (flags mask) (station-flags l)
  (let ((p (getf (command-ok (link-card l) 0 #x18
                             (octets (if modify 1 0) 0 0 0 (le-u32 0) (link-bssid l) 0 0 0 0 0 0
                                     (le-u32 flags) (le-u32 mask)
                                     (zeros 6) 0 0 (le-u16 (or (link-aid l) 0)) 0 0 (le-u32 0) 0 0 0 0))
                 :payload)))
    (unless (= 1 (logand #xFF (u32le p 0))) (error "the AX210 refused the station: ~x" (u32le p 0))))))

(defun mac-context (l action assoc)
  (let* ((w (link-card l)) (bss (link-bss l))
         (interval (getf bss :interval 100))
         (edca '((1 15 1023 3 0) (0 15 1023 7 0) (2 7 15 2 94) (3 3 7 2 47)))
         (ac (zeros 40)))
    (loop for (fifo cwmin cwmax aifsn txop) in edca
          do (replace ac (octets (le-u16 cwmin) (le-u16 cwmax) aifsn (ash 1 fifo) (le-u16 (* 32 txop))) :start1 (* 8 fifo)))
    (octets (le-u32 0) (le-u32 (ecase action (:add 1) (:modify 2) (:remove 3)))
            (le-u32 5) (le-u32 0) (getf (card-nvm w) :mac) 0 0 (link-bssid l) 0 0
            (le-u32 0) (le-u32 #x15) (le-u32 0) (le-u32 0) (le-u32 (ash 1 4))
            (le-u32 (logior (ash 1 2) (if assoc 0 (ash 1 6))))
            (le-u32 (logior 1 (if (link-ht l) 2 0))) ac
            (le-u32 (if assoc 1 0)) (le-u32 (if assoc (getf bss :gp2 0) 0))
            (le-u32 (ldb (byte 32 0) (if assoc (getf bss :tsf 0) 0))) (le-u32 (ash (if assoc (getf bss :tsf 0) 0) -32))
            (le-u32 interval) (le-u32 0) (le-u32 (* interval (getf bss :dtim 1))) (le-u32 0) (le-u32 10)
            (le-u32 (or (link-aid l) 0)) (le-u32 (if assoc (getf bss :gp2 0) 0)) (le-u32 0))))

(defparameter +rates-5ghz+ (octets #x8C #x12 #x98 #x24 #xB0 #x48 #x60 #x6C))

(defparameter +ht-capabilities+
  (octets 45 26 (le-u16 #x012D) #x17 #xFF #xFF (zeros 10) 1 0 0 0 (le-u16 0) (le-u32 0) 0))

(defparameter +wmm-information+ (octets 221 7 0 #x50 #xF2 2 0 1 0))

(defun ht-from (elements)
  (let ((caps (cdr (assoc 45 elements))))
    (when (and caps (>= (length caps) 3))
      (let ((info (logior (aref caps 0) (ash (aref caps 1) 8))))
        (list :sgi20 (logbitp 5 info) :rx-stbc (plusp (ldb (byte 2 8) info))
              :exponent (ldb (byte 2 0) (aref caps 2)) :density (ldb (byte 3 2) (aref caps 2))
              :streams (if (and (>= (length caps) 5) (plusp (aref caps 4))) 2 1))))))

(defun authenticate (l)
  (let ((w (link-card l)) (bssid (link-bssid l)))
    (dotimes (try 3 (error "the access point did not answer authentication"))
      (transmit l (octets (frame-header #xB0 0 bssid (getf (card-nvm w) :mac) bssid (next-seq l)) (le-u16 0) (le-u16 1) (le-u16 0)))
      (let ((f (take-frame l (lambda (f) (from-bss-p l f #xB0)) 1)))
        (when f
          (let ((status (logior (aref f 28) (ash (aref f 29) 8))))
            (unless (zerop status) (error "authentication refused, status ~d" status))
            (return t)))))))

(defun associate (l ssid)
  (let ((w (link-card l)) (bssid (link-bssid l)))
    (dotimes (try 3 (error "the access point did not answer association"))
      (transmit l (octets (frame-header 0 0 bssid (getf (card-nvm w) :mac) bssid (next-seq l))
                          (le-u16 #x0011) (le-u16 10)
                          0 (length ssid) (map 'list #'char-code ssid)
                          1 (length +rates-5ghz+) +rates-5ghz+
                          +rsn-psk-ccmp+
                          (if (link-want-ht l) (octets +ht-capabilities+ +wmm-information+) #())))
      (let ((f (take-frame l (lambda (f) (from-bss-p l f #x10)) 1)))
        (when f
          (let ((status (logior (aref f 26) (ash (aref f 27) 8))))
            (unless (zerop status) (error "association refused, status ~d" status))
            (setf (link-aid l) (logand #x3FFF (logior (aref f 28) (ash (aref f 29) 8)))
                  (link-ht l) (and (link-want-ht l) (ht-from (elements (subseq f 30)))))
            (return (link-aid l))))))))

(defun after-association (l)
  (let ((w (link-card l)))
    (add-station l t)
    (command-ok w 0 #x28 (mac-context l :modify t))
    (command-ok w 0 #xD1 (octets (le-u32 1) (le-u32 4096) (le-u32 4096)
                                 (loop repeat 10 append (le-u32 1000000))
                                 (loop for (aging idle) in '((2016 320) (2016 320) (10016 2016) (2016 320) (2016 320))
                                       append (append (le-u32 aging) (le-u32 idle)))))
    (command-ok w 0 #xD0 (octets 1 0 0 1 (link-bssid l) 0 0))
    (set-power-save l *power-save*)
    (send-command w 5 #xF (rate-config l))
    (when (link-ht l)
      (setf (link-data l) (ignore-errors (add-queue l 0))))))

(defun rate-config (l)
  (let ((ht (link-ht l)))
    (if ht
        (let ((two (= 2 (getf ht :streams))))
          (octets 0 0 0 0 0 1 (if two 3 1) (if (getf ht :sgi20) 1 0)
                  (le-u16 (if (and two (getf ht :rx-stbc)) 1 0)) (le-u16 #xFF0)
                  (le-u16 #xFF) (le-u16 0) (le-u16 0) (le-u16 (if two #xFF 0)) (le-u16 0) (le-u16 0)
                  (le-u16 3839) (le-u16 0)))
        (octets 0 0 0 0 0 0 1 0 (le-u16 0) (le-u16 #xFF0) (zeros 12) (le-u16 2346) (le-u16 0)))))

(defparameter +power-levels+ '((0 0 0) (1 200 500) (2 200 300) (3 50 100)))

(defun set-power-save (l level)
  (destructuring-bind (rx tx) (rest (assoc level +power-levels+))
    (let ((w (link-card l)) (on (plusp level)))
      (command-ok w 0 #x77 (octets (le-u16 (if on 1 0)) 0 0))
      (command-ok w 0 #xA9 (octets (le-u32 0) (le-u16 (if on 3 0)) (le-u16 25)
                                   (le-u32 (* rx 1024)) (le-u32 (* tx 1024)) (le-u32 0) (le-u32 0)
                                   (zeros 16)))
      level)))

(defun eapol-frame (l body)
  (let ((w (link-card l)) (bssid (link-bssid l)))
    (octets (frame-header 8 1 bssid (getf (card-nvm w) :mac) bssid (next-seq l))
            #xAA #xAA 3 0 0 0 #x88 #x8E body)))

(defun data-payload (frame)
  (let* ((h (header-length frame))
         (protected (logbitp 6 (aref frame 1)))
         (body (subseq frame (+ h (if protected 8 0)))))
    (when (and (>= (length body) 8) (equalp (subseq body 0 6) #(#xAA #xAA 3 0 0 0)))
      (values (logior (ash (aref body 6) 8) (aref body 7)) (subseq body 8)))))

(defun block-ack-action (l f)
  (and (>= (length f) 26) (= (aref f 0) #xD0) (equalp (subseq f 10 16) (link-bssid l))
       (= (aref f 24) 3)
       (case (aref f 25)
         (0 (and (>= (length f) 33) 0))
         (2 (and (>= (length f) 30) 2)))))

(defun remove-block-ack (l tid)
  (let ((old (assoc tid (link-block-acks l))))
    (when old
      ;; RX_BAID_ALLOCATION_CONFIG_CMD has a 12-byte union after action,
      ;; including for remove. Version 1 identifies the BAID, version 2 the TID.
      (let* ((w (link-card l))
             (version (or (command-version (card-firmware w) 5 #x16) 1)))
        (command-ok w 5 #x16
                    (if (= version 1)
                        (octets (le-u32 2) (le-u32 (cdr old)) (zeros 8))
                        (octets (le-u32 2) (le-u32 1) (le-u32 tid) (zeros 4)))))
      ;; Retain ownership when the firmware did not acknowledge removal.
      (setf (link-block-acks l) (remove tid (link-block-acks l) :key #'car)))))

(defun answer-addba (l f)
  (sb-thread:with-recursive-lock ((link-lock l))
    (when (link-retired l) (return-from answer-addba nil))
    (let* ((token (aref f 26))
           (params (logior (aref f 27) (ash (aref f 28) 8)))
           (timeout (logior (aref f 29) (ash (aref f 30) 8)))
           (ssn (ash (logior (aref f 31) (ash (aref f 32) 8)) -4))
           (tid (ldb (byte 4 2) params))
           (size (let ((asked (ldb (byte 10 6) params))) (if (zerop asked) 64 (min 64 asked))))
           (baid (ignore-errors
                   ;; A repeated request must retire the previous session before
                   ;; allocating this TID again; duplicate allocation asserts firmware.
                   (remove-block-ack l tid)
                   (let ((id (u32le (getf (command-ok (link-card l) 5 #x16
                                                     (octets (le-u32 0) (le-u32 1) tid 0 0 0 (le-u16 ssn) (le-u16 size)))
                                         :payload) 0)))
                     (and (< id 32) id))))
           (bssid (link-bssid l)))
      (when baid
        (push (cons tid baid) (link-block-acks l)))
      (transmit l (octets (frame-header #xD0 0 bssid (getf (card-nvm (link-card l)) :mac) bssid (next-seq l))
                          3 1 token (le-u16 (if baid 0 37))
                          (le-u16 (logior 2 (ash tid 2) (ash size 6))) (le-u16 timeout)))
      (list :tid tid :ssn ssn :size size :baid baid))))

(defun end-block-ack (l f)
  (sb-thread:with-recursive-lock ((link-lock l))
    (when (link-retired l) (return-from end-block-ack nil))
    (let ((params (logior (aref f 26) (ash (aref f 27) 8))))
      ;; Only the peer's originator session corresponds to our receive BAID.
      (when (logbitp 11 params)
        (remove-block-ack l (ldb (byte 4 12) params))))))

(defun data-from-bss-p (l f)
  (and (>= (length f) 24) (= 2 (ldb (byte 2 2) (aref f 0))) (= 2 (logand 3 (aref f 1)))
       (equalp (subseq f 10 16) (link-bssid l))))

(defun install-key (l key index group)
  (let* ((flags (logior 2 (ash 1 3) (ash index 8) (if group (ash 1 14) 0)))
         (p (getf (command-ok (link-card l) 0 #x17
                              (octets 0 (if group 1 0) (le-u16 flags) key (zeros (- 32 (length key))) (zeros 16)
                                      (zeros 8) (zeros 8) (zeros 8)))
                  :payload)))
    (unless (= 1 (logand #xFF (u32le p 0))) (error "the AX210 refused the key: ~x" (u32le p 0)))))

(defun handshake (l pmk)
  (let* ((w (link-card l))
         (s (make-supplicant :pmk pmk :own (getf (card-nvm w) :mac) :peer (link-bssid l))))
    (setf (link-supplicant l) s)
    (loop with deadline = (+ (microseconds) 10000000)
          until (eq (supplicant-state s) :keyed)
          do (when (> (microseconds) deadline) (error "the WPA2 handshake did not finish (~a)" (supplicant-state s)))
             (let ((f (take-frame l (lambda (f) (and (data-from-bss-p l f) (eql +eapol-ethertype+ (data-payload f)))) 1)))
               (when f
                 (multiple-value-bind (type body) (data-payload f)
                   (declare (ignore type))
                   (multiple-value-bind (reply events) (supplicant-receive s body)
                     (when reply (transmit l (eapol-frame l reply)))
                     (dolist (e events)
                       (case (first e)
                         (:pairwise (install-key l (second e) 0 nil))
                         (:group (install-key l (second e) (third e) t)))))))))
    (setf (link-keyed l) t)))

(defvar *link* nil)

(defun join (ssid passphrase &key (card *card*) (ht *ht*))
  (let ((bss (or (find-network card ssid) (error "no network called ~s in range" ssid))))
      (let ((l (make-instance 'link :card card :bss bss :bssid (mac-octets (getf bss :bssid)) :want-ht ht)))
        (setf *link* l)
        (context-commands l)
        (authenticate l)
        (associate l ssid)
        (after-association l)
        (handshake l (passphrase-pmk passphrase ssid))
        (note card :joined :ssid ssid :bssid (getf bss :bssid) :aid (link-aid l))
        l)))

(defun find-network (card ssid &key (tries 3))
  (loop repeat tries
        thereis (find ssid (scan card) :key (lambda (b) (getf b :ssid)) :test #'equal)))

(devices:define-device-class wireless-interface "WirelessInterface" (devices:ethernet-controller)
  ((link :initarg :link :accessor wireless-link)
   (rejoining :initform nil :accessor wireless-rejoining)
   (mac :initarg :mac :accessor devices:network-mac)))

(defmethod devices:interrupt-vector ((d wireless-interface)) (card-vector (link-card (wireless-link d))))

(defun acknowledge-interrupts (w)
  (let ((fh (reg w #x2800)) (hw (reg w #x2808)))
    (setf (reg w #x2800) fh (reg w #x2808) hw (reg w #x2810) 1)
    (values fh hw)))

(defun wireless-up-p (d)
  (and (not (wireless-rejoining d)) (link-keyed (wireless-link d))))

(defparameter *missed-beacons-limit* 20)

(defun wifi-settings ()
  (with-open-file (s *wifi-settings*)
    (values (read-line s) (read-line s))))

(defvar *starting* (sb-thread:make-mutex :name "wifi start"))

(defun rejoin (d)
  (loop for wait in '(0 2 5 10 30 30 60)
        for try from 0
        do (sleep wait)
           (handler-case
               (sb-thread:with-mutex (*starting*)
                 (multiple-value-bind (ssid pass) (wifi-settings)
                   (retire-link *link*)
                   (setf *link* nil)
                   (bring-up)
                   (setf (wireless-link d) (join ssid pass :ht (and *ht* (zerop try))))
                   (return t)))
             (error (e) (note *card* :rejoin-failed (princ-to-string e))))
        finally (return nil)))

(defun lost (d why &optional (l (wireless-link d)))
  (sb-thread:with-recursive-lock ((link-lock l))
    (when (and (eq l (wireless-link d)) (not (wireless-rejoining d)))
      (setf (wireless-rejoining d) why)
      (retire-link l)
      (note (link-card l) :lost why)
      (sb-thread:make-thread
       (lambda () (unwind-protect (rejoin d) (setf (wireless-rejoining d) nil)))
       :name "wifi rejoin"))))

(defun lost-signal (l p f)
  (cond ((and f (= (getf p :code) #xC1) (member (aref f 0) '(#xC0 #xA0))
              (equalp (subseq f 10 16) (link-bssid l)))
         (if (= (aref f 0) #xC0) :deauthenticated :disassociated))
        ((and (= (getf p :code) #xA2) (>= (length (getf p :payload)) 8)
              (> (u32le (getf p :payload) 4) *missed-beacons-limit*))
         :beacons-lost)))

(defmethod devices:network-send ((d wireless-interface) frame)
  (unless (wireless-up-p d) (return-from devices:network-send 0))
  (let* ((l (wireless-link d))
         (frame (octets frame))
         (dst (subseq frame 0 6)) (src (subseq frame 6 12)))
    (sb-thread:with-recursive-lock ((link-lock l))
      (unless (and (eq l (wireless-link d)) (wireless-up-p d))
        (return-from devices:network-send 0))
      (let ((data (link-data l)))
        (if data
            (transmit l (octets (frame-header #x88 (logior 1 #x40) (link-bssid l) src dst (next-data-seq data))
                                0 0 #xAA #xAA 3 0 0 0 (subseq frame 12))
                      :encrypt t :queue data)
            (transmit l (octets (frame-header 8 (logior 1 #x40) (link-bssid l) src dst (next-seq l))
                                #xAA #xAA 3 0 0 0 (subseq frame 12))
                      :encrypt t))))
    (length frame)))

(defun ethernet-from (f)
  (multiple-value-bind (type body) (data-payload f)
    (when type
      (octets (subseq f 4 10) (subseq f 16 22) (ldb (byte 8 8) type) (ldb (byte 8 0) type) body))))

(defun decrypted-p (f status)
  (or (not (logbitp 6 (aref f 1)))
      (and (= (logand status (ash 7 8)) (ash 2 8)) (logbitp 11 status) (logbitp 6 status))))

(defmethod devices:network-receive ((d wireless-interface))
  (unless (wireless-up-p d) (sleep 0.1) (return-from devices:network-receive nil))
  (let* ((l (wireless-link d)) (w (link-card l)) (out nil) (lost nil))
    (sb-thread:with-recursive-lock ((link-lock l))
      (unless (and (eq l (wireless-link d)) (wireless-up-p d))
        (return-from devices:network-receive nil))
      (multiple-value-bind (fh hw) (acknowledge-interrupts w)
        (when (or (logtest hw (logior (ash 1 3) (ash 1 5) (ash 1 25) (ash 1 29))) (logbitp 21 fh))
          (setf lost :firmware-error)))
      (pump w)
      (let ((missed (sb-thread:with-recursive-lock ((card-pump-lock w))
                      (prog1 (find-if (lambda (p) (= (getf p :code) #xA2)) (card-notifications w))
                        (setf (card-notifications w) (remove #xA2 (card-notifications w) :key (lambda (p) (getf p :code))))))))
        (when missed (setf lost (lost-signal l missed nil))))
      (dolist (p (take-mpdus w))
        (multiple-value-bind (f status channel gp2 signal) (mpdu (getf p :payload))
          (declare (ignore channel gp2))
          (setf lost (or lost (lost-signal l p f)))
          (when (and f signal (> signal -256) (>= (length f) 16) (equalp (subseq f 10 16) (link-bssid l)))
            (setf (link-signal l) (if (link-signal l) (round (+ (* 7 (link-signal l)) signal) 8) signal)))
          (progn
            (let ((action (and f (block-ack-action l f))))
              (when action
                (sb-thread:make-thread (if (zerop action) #'answer-addba #'end-block-ack)
                                       :name "wifi block ack" :arguments (list l f))))
            (when (and f (data-from-bss-p l f) (decrypted-p f status))
              (if (eql +eapol-ethertype+ (data-payload f))
                  (multiple-value-bind (reply events) (supplicant-receive (link-supplicant l) (nth-value 1 (data-payload f)))
                    (when reply (transmit l (eapol-frame l reply)))
                    (dolist (e events)
                      (when (eq (first e) :group) (install-key l (second e) (third e) t))))
                  (let ((e (ethernet-from f))) (when e (push e out)))))))))
    (when lost (lost d lost l))
    (nreverse out)))

(defvar *wifi-confirmed* nil)

(defun use-wifi (ssid passphrase &key (fallback-seconds 120))
  (let* ((l (sb-thread:with-mutex (*starting*)
              (or (and *link* (link-keyed *link*) *link*)
                  (progn (retire-link *link*) (setf *link* nil)
                         (bring-up) (join ssid passphrase)))))
         (d (make-instance 'wireless-interface :link l :mac (getf (card-nvm (link-card l)) :mac)))
         (old (darterfly/net::interface-device darterfly/net:*interface*)))
    (setf *wifi-confirmed* nil)
    (sb-thread:make-thread
     (lambda ()
       (sleep fallback-seconds)
       (unless *wifi-confirmed*
         (darterfly/net::interface-detach d)
         (when old (darterfly/net::interface-attach old))))
     :name "wifi fallback")
    (sb-thread:make-thread
     (lambda ()
       (sleep 2)
       (when old (darterfly/net::interface-detach old))
       (darterfly/net::interface-attach d))
     :name "wifi switch")
    d))

(defun start-wifi ()
  (darterfly/net:start-network)
  (sb-thread:with-mutex (*starting*)
    (when (and (probe-file *wifi-settings*)
               (not (darterfly/net::interface-device darterfly/net:*interface*)))
      (multiple-value-bind (ssid pass) (wifi-settings)
        (retire-link *link*)
        (setf *link* nil)
        (bring-up)
        (darterfly/net::interface-attach
         (make-instance 'wireless-interface :link (join ssid pass) :mac (getf (card-nvm *card*) :mac)))))))

(defun wired-p (device)
  (and (typep device 'devices:ethernet-controller) (not (typep device 'wireless-interface))))

(defun wifi-device-changed (event device)
  (when (and (wired-p device) darterfly/net:*interface* (probe-file *wifi-settings*))
    (case event
      (:added
       (let ((current (darterfly/net::interface-device darterfly/net:*interface*)))
         (when (typep current 'wireless-interface)
           (sb-thread:make-thread
            (lambda ()
              (darterfly/net::interface-detach current)
              (darterfly/net::interface-attach device))
            :name "wifi to cable"))))
      (:removed
       (sb-thread:make-thread
        (lambda ()
          (sleep 1)
          (unless (darterfly/net::interface-device darterfly/net:*interface*)
            (start-wifi)))
        :name "cable to wifi")))))

(pushnew 'wifi-device-changed devices:*device-hooks*)

(defun wifi-woke (event device)
  (declare (ignore device))
  (when (eq event :woke)
    ;; Firmware state is lost even when Ethernet was selected during sleep.
    (retire-link *link*)
    (let ((d (and darterfly/net:*interface* (darterfly/net::interface-device darterfly/net:*interface*))))
      (when (typep d 'wireless-interface) (lost d :woke)))))

(pushnew 'wifi-woke devices:*device-hooks*)

(defun confirm-wifi ()
  (setf *wifi-confirmed* t))

(defun network-status ()
  (let ((d (and darterfly/net:*interface* (darterfly/net::interface-device darterfly/net:*interface*))))
    (cond ((typep d 'wireless-interface)
           (let ((l (wireless-link d)))
             (list :kind :wifi :up (wireless-up-p d) :signal (link-signal l)
                   :rejoining (wireless-rejoining d)
                   :ssid (and (link-bss l) (getf (link-bss l) :ssid)))))
          (d (list :kind :wired :up t))
          (t (list :kind :none :up nil)))))
