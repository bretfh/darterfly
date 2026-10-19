(in-package #:darterfly/audio)

(defconstant +mix-frames+ 1024)

(defstruct source data (at 0))

(defvar *mixer-lock* (sb-thread:make-mutex :name "audio mixer"))
(defvar *mixer-wake* (sb-thread:make-waitqueue :name "audio mixer"))
(defvar *sources* nil)
(defvar *mixer-thread* nil)
(defvar *mixer-output* nil)

(pushnew 'forget-mixer sb-ext:*save-hooks*)

(defun forget-mixer () (setf *sources* nil *mixer-thread* nil *mixer-output* nil))

(defun sample (v i)
  (let ((u (logior (aref v i) (ash (aref v (1+ i)) 8))))
    (if (logbitp 15 u) (- u #x10000) u)))

(defun mix-period ()
  (let ((sums (make-array (* 2 +mix-frames+) :element-type 'fixnum :initial-element 0))
        (out (make-array (* 4 +mix-frames+) :element-type '(unsigned-byte 8))))
    (sb-thread:with-mutex (*mixer-lock*)
      (dolist (s *sources*)
        (let* ((v (source-data s)) (at (source-at s)) (n (min (* 4 +mix-frames+) (- (length v) at))))
          (loop for i from 0 below n by 2
                do (incf (aref sums (floor i 2)) (sample v (+ at i))))
          (incf (source-at s) n)))
      (setf *sources* (remove-if (lambda (s) (>= (source-at s) (length (source-data s)))) *sources*)))
    (dotimes (i (* 2 +mix-frames+) out)
      (let ((v (logand #xFFFF (max -32768 (min 32767 (aref sums i))))))
        (setf (aref out (* 2 i)) (ldb (byte 8 0) v) (aref out (1+ (* 2 i))) (ldb (byte 8 8) v))))))

(defun mixer-loop ()
  (loop
    (sb-thread:with-mutex (*mixer-lock*)
      (loop until *sources* do (sb-thread:condition-wait *mixer-wake* *mixer-lock*)))
    (handler-case
        (let ((period (mix-period)))
          (unless *mixer-output*
            (setf *mixer-output* (open-output (or (default-output-device) (error "no audio device")))))
          (output-write *mixer-output* period))
      (error (e)
        (format *error-output* "~&audio mixer: ~a~%" e)
        (sb-thread:with-mutex (*mixer-lock*) (setf *sources* nil))))))

(defun start-audio ()
  (loop repeat 200 until devices:*registry-root* do (sleep 0.05))
  (unless (and *mixer-thread* (sb-thread:thread-alive-p *mixer-thread*))
    (setf *mixer-thread* (sb-thread:make-thread #'mixer-loop :name "audio mixer")))
  (default-output-device))

(defun play (octets)
  (start-audio)
  (let ((s (make-source :data (coerce octets '(simple-array (unsigned-byte 8) (*))))))
    (sb-thread:with-mutex (*mixer-lock*)
      (setf *sources* (append *sources* (list s)))
      (sb-thread:condition-broadcast *mixer-wake*))
    s))

(defun tone-octets (hz seconds level)
  (let* ((frames (round (* 48000 seconds))) (v (make-array (* 4 frames) :element-type '(unsigned-byte 8))))
    (dotimes (i frames v)
      (let ((s (logand #xFFFF (round (* level 32767 (sin (/ (* 2 pi hz i) 48000)))))))
        (setf (aref v (* 4 i)) (ldb (byte 8 0) s) (aref v (+ 1 (* 4 i))) (ldb (byte 8 8) s)
              (aref v (+ 2 (* 4 i))) (ldb (byte 8 0) s) (aref v (+ 3 (* 4 i))) (ldb (byte 8 8) s))))))

(defun play-tone (&key (hz 440) (seconds 0.5) (level 0.3))
  (play (tone-octets hz seconds level)))

(defun volume () (let ((d (default-output-device))) (and d (device-volume d))))
(defun (setf volume) (v) (let ((d (default-output-device))) (and d (setf (device-volume d) v))))
(defun mute (&optional (on t)) (let ((d (default-output-device))) (and d (setf (device-mute d) on))))

(defun audio-status ()
  (list :devices (mapcar #'device-status (audio-devices))
        :sources (length *sources*)))
