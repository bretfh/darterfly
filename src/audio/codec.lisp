(in-package #:darterfly/audio)

(defun param (c cad nid p) (verb c cad nid #xF00 p))

(defun nodes (c cad nid)
  (let ((v (param c cad nid 4)))
    (loop for i below (ldb (byte 8 0) v) collect (+ i (ldb (byte 8 16) v)))))

(defun connections (c cad nid)
  (let* ((len (param c cad nid #x0E)) (n (ldb (byte 7 0) len)) (long (logbitp 7 len)))
    (subseq (loop for i from 0 below n by (if long 2 4)
                  append (let ((v (verb c cad nid #xF02 i)))
                           (if long
                               (list (ldb (byte 16 0) v) (ldb (byte 16 16) v))
                               (list (ldb (byte 8 0) v) (ldb (byte 8 8) v) (ldb (byte 8 16) v) (ldb (byte 8 24) v)))))
            0 n)))

(defun read-codec (c cad)
  (let ((afg (find-if (lambda (n) (= 1 (ldb (byte 8 0) (param c cad n 5)))) (nodes c cad 0))))
    (when afg
      (make-codec
       :controller c :address cad :vendor (param c cad 0 0) :afg afg
       :widgets (loop for nid in (nodes c cad afg)
                      for caps = (param c cad nid 9)
                      for type = (nth (ldb (byte 4 20) caps) '(:out :in :mixer :selector :pin :power :volume :beep))
                      collect (make-widget :nid nid :type type :caps caps
                                           :connections (if (logbitp 8 caps) (connections c cad nid) nil)
                                           :pin-caps (and (eq type :pin) (param c cad nid #x0C))
                                           :config (and (eq type :pin) (verb c cad nid #xF1C 0))
                                           :amp-out-caps (and (logbitp 2 caps)
                                                              (let ((a (param c cad nid #x12)))
                                                                (if (zerop a) (param c cad afg #x12) a)))))))))

(defun codec-verb (codec nid v payload) (verb (codec-controller codec) (codec-address codec) nid v payload))

(defun widget (codec nid) (find nid (codec-widgets codec) :key #'widget-nid))

(defun pin-device (w) (nth (ldb (byte 4 20) (widget-config w)) '(:line-out :speaker :hp-out :cd :spdif-out :digital-out :modem-line :modem-hand :line-in :aux :mic-in :telephony :spdif-in :digital-in :reserved :other)))
(defun pin-connected (w) (nth (ldb (byte 2 30) (widget-config w)) '(:jack :none :fixed :both)))

(defun output-pins (codec)
  (remove-if-not (lambda (w) (and (eq (widget-type w) :pin) (not (eq (pin-connected w) :none))
                                  (member (pin-device w) '(:speaker :hp-out :line-out))))
                 (codec-widgets codec)))

(defun path-to-dac (codec pin)
  (let ((seen nil))
    (labels ((walk (w)
               (unless (member (widget-nid w) seen)
                 (push (widget-nid w) seen)
                 (if (eq (widget-type w) :out)
                     (list w)
                     (when (member (widget-type w) '(:pin :mixer :selector))
                       (dolist (n (widget-connections w))
                         (let* ((next (widget codec n)) (rest (and next (walk next))))
                           (when rest (return (cons w rest))))))))))
      (walk pin))))

(defun plugged-p (codec pin)
  (and (eq (pin-connected pin) :jack) (logbitp 2 (widget-pin-caps pin))
       (progn (codec-verb codec (widget-nid pin) #x709 0)
              (logbitp 31 (codec-verb codec (widget-nid pin) #xF09 0)))))

(defun choose-pin (codec)
  (let ((pins (output-pins codec)))
    (or (find-if (lambda (p) (and (eq (pin-device p) :hp-out) (plugged-p codec p))) pins)
        (find :speaker pins :key #'pin-device)
        (first pins))))

(defun set-amp (codec nid &key out (index 0) mute (gain 0))
  (codec-verb codec nid 3 (logior (if out (ash 1 15) (ash 1 14)) (ash 1 13) (ash 1 12) (ash index 8) (if mute #x80 0) gain)))

(defun volume-gain (caps volume)
  (let* ((zero (ldb (byte 7 0) caps))
         (step-db (* 0.25 (1+ (ldb (byte 7 16) caps))))
         (db (if (plusp volume) (* 20 (log volume 10)) -1000)))
    (max 0 (min zero (round (+ zero (/ db step-db)))))))

(defun open-path (codec path tag)
  (codec-verb codec (codec-afg codec) #x705 0)
  (loop for (w next) on path
        do (codec-verb codec (widget-nid w) #x705 0)
           (when next
             (let ((index (position (widget-nid next) (widget-connections w))))
               (case (widget-type w)
                 ((:pin :selector) (when (> (length (widget-connections w)) 1) (codec-verb codec (widget-nid w) #x701 index)))
                 (:mixer (loop for i below (length (widget-connections w))
                               do (set-amp codec (widget-nid w) :index i :mute (/= i index)))))))
           (when (and (logbitp 2 (widget-caps w)) (not (eq (widget-type w) :out)))
             (set-amp codec (widget-nid w) :out t :gain (ldb (byte 7 0) (or (widget-amp-out-caps w) 0)))))
  (let ((pin (first path)) (dac (car (last path))))
    (codec-verb codec (widget-nid pin) #x707 (logior #x40 (if (logbitp 3 (widget-pin-caps pin)) #x80 0)))
    (when (logbitp 16 (widget-pin-caps pin)) (codec-verb codec (widget-nid pin) #x70C 2))
    (codec-verb codec (widget-nid dac) 2 #x0011)
    (codec-verb codec (widget-nid dac) #x706 (ash tag 4))
    dac))

(defun path-volume (codec path volume muted)
  (let ((dac (car (last path))))
    (set-amp codec (widget-nid dac) :out t :mute (or muted (<= volume 0))
             :gain (volume-gain (or (widget-amp-out-caps dac) 0) (max 0 (min 1 volume))))))

(defun close-path (codec path)
  (codec-verb codec (widget-nid (car (last path))) #x706 0)
  (codec-verb codec (widget-nid (first path)) #x707 0)
  (when (logbitp 16 (widget-pin-caps (first path))) (codec-verb codec (widget-nid (first path)) #x70C 0)))
