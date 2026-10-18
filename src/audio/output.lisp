(in-package #:darterfly/audio)

(defconstant +period-bytes+ 4096)
(defconstant +periods+ 16)
(defconstant +ring-bytes+ (* +period-bytes+ +periods+))
(defconstant +stream-tag+ 1)

(defvar *audio-lock* (sb-thread:make-mutex :name "audio"))
(defvar *codec* nil)
(defvar *path* nil)
(defvar *ring* nil)
(defvar *bdl* nil)
(defvar *vector* nil)
(defvar *running* nil)
(defvar *suspended* nil)
(defvar *written* 0)
(defvar *played* 0)
(defvar *last-lpib* 0)
(defvar *last-active* 0)
(defvar *volume* 0.5)
(defvar *muted* nil)
(defvar *idle-thread* nil)

(pushnew 'forget-audio sb-ext:*save-hooks*)

(defun forget-audio ()
  (setf *codec* nil *path* nil *ring* nil *bdl* nil *vector* nil *running* nil *suspended* nil *idle-thread* nil))

(defun stream-base () (+ #x80 (* #x20 (input-streams))))

(defun now () (get-internal-real-time))

(defun phys-zero (pa n) (loop for i from 0 below n by 8 do (devices::ml-phys-write-64 (+ pa i) 0)))

(defun ring-write (offset data start end)
  (loop for i from start below end
        for at = (mod (+ offset (- i start)) +ring-bytes+)
        do (devices::ml-phys-write-8 (+ *ring* at) (aref data i))))

(defun ring-zero (offset n)
  (loop for i below n
        for at = (mod (+ offset i) +ring-bytes+)
        do (devices::ml-phys-write-8 (+ *ring* at) 0)))

(defun bring-up ()
  (reset-controller)
  (unless (logbitp 0 (reg #x0E 16)) (error "hda: no codec at address 0"))
  (setf *codec* (read-codec 0))
  (unless *ring*
    (setf *ring* (devices:vm-pages-grab (ceiling +ring-bytes+ 4096))
          *bdl* (devices:vm-page-grab)))
  (dotimes (i +periods+)
    (devices::ml-phys-write-64 (+ *bdl* (* 16 i)) (+ *ring* (* i +period-bytes+)))
    (devices::ml-phys-write-32 (+ *bdl* (* 16 i) 8) +period-bytes+)
    (devices::ml-phys-write-32 (+ *bdl* (* 16 i) 12) 1))
  (unless *vector*
    (setf *vector* (devices:allocate-vector)))
  (when *vector* (devices::enable-msi (controller) *vector*))
  (setf (reg #x20 32) (logior (ash 1 31) (ash 1 (input-streams))))
  (setf *suspended* nil))

(defun start-audio ()
  (sb-thread:with-recursive-lock (*audio-lock*)
    (when (controller)
      (bring-up)
      (unless (and *idle-thread* (sb-thread:thread-alive-p *idle-thread*))
        (setf *idle-thread* (sb-thread:make-thread #'idle-loop :name "audio idle")))
      (codec-vendor *codec*))))

(defun apply-volume ()
  (when *path*
    (let* ((dac (car (last *path*)))
           (steps (ldb (byte 7 8) (or (widget-amp-out-caps dac) 0))))
      (set-amp (codec-address *codec*) (widget-nid dac) :out t
               :mute (or *muted* (<= *volume* 0)) :gain (round (* steps (max 0 (min 1 *volume*))))))))

(defun start-stream ()
  (when *suspended* (bring-up))
  (let ((sd (stream-base))
        (pin (choose-pin *codec*)))
    (setf *path* (path-to-dac *codec* pin))
    (unless *path* (error "hda: no path from pin ~x to a DAC" (widget-nid pin)))
    (open-path *codec* *path* +stream-tag+)
    (apply-volume)
    (setf (reg sd 8) 1)
    (wait-for "the stream to enter reset" (lambda () (logbitp 0 (reg sd 8))))
    (setf (reg sd 8) 0)
    (wait-for "the stream to leave reset" (lambda () (not (logbitp 0 (reg sd 8)))))
    (setf (reg (+ sd 2) 8) (ash +stream-tag+ 4)
          (reg (+ sd 8) 32) +ring-bytes+
          (reg (+ sd #x0C) 16) (1- +periods+)
          (reg (+ sd #x12) 16) #x0011
          (reg (+ sd #x18) 32) (ldb (byte 32 0) *bdl*)
          (reg (+ sd #x1C) 32) (ash *bdl* -32))
    (phys-zero *ring* +ring-bytes+)
    (setf *played* 0 *last-lpib* 0 *written* +period-bytes+)
    (setf (reg sd 8) (logior 2 4))
    (setf *running* t)))

(defun stop-stream ()
  (let ((sd (stream-base)))
    (setf (reg sd 8) 0)
    (setf (reg (+ sd 3) 8) #x1C)
    (when *path* (close-path *codec* *path*))
    (setf *running* nil)))

(defun update-played ()
  (let* ((sd (stream-base)) (lpib (reg (+ sd 4) 32)))
    (incf *played* (mod (- lpib *last-lpib*) +ring-bytes+))
    (setf *last-lpib* lpib)
    (setf (reg (+ sd 3) 8) #x1C)))

(defun wait-for-room (n)
  (loop
    (update-played)
    (when (< *written* *played*) (setf *written* (+ *played* +period-bytes+)))
    (when (<= (+ (- *written* *played*) n) (- +ring-bytes+ +period-bytes+)) (return))
    (sb-thread:release-mutex *audio-lock*)
    (unwind-protect
         (if *vector* (devices:wait-for-interrupt (list *vector*) 0.05) (sleep 0.005))
      (sb-thread:grab-mutex *audio-lock*))))

(defun write-pcm (data &key (start 0) (end (length data)))
  (sb-thread:with-recursive-lock (*audio-lock*)
    (unless *codec* (error "audio is not started"))
    (unless *running* (start-stream))
    (loop with at = start
          while (< at end)
          do (let ((n (min (- end at) +period-bytes+)))
               (wait-for-room n)
               (ring-write (mod *written* +ring-bytes+) data at (+ at n))
               (incf *written* n)
               (ring-zero (mod *written* +ring-bytes+) (min +period-bytes+ (- +ring-bytes+ (- *written* *played*))))
               (incf at n)))
    (setf *last-active* (now))
    (- end start)))

(defun idle-loop ()
  (loop
    (sleep 0.25)
    (ignore-errors
     (sb-thread:with-recursive-lock (*audio-lock*)
       (let ((quiet (/ (- (now) *last-active*) internal-time-units-per-second)))
         (when *running*
           (update-played)
           (when (and (>= *played* *written*) (> quiet 0.5))
             (stop-stream)))
         (when (and (not *running*) (not *suspended*) (> quiet 5))
           (setf (reg #x20 32) 0)
           (verb 0 (codec-afg *codec*) #x705 3)
           (setf (power-state (controller)) 3)
           (setf *suspended* t)))))))

(defun volume () *volume*)

(defun (setf volume) (value)
  (sb-thread:with-recursive-lock (*audio-lock*)
    (setf *volume* (max 0.0 (min 1.0 (float value))))
    (when *running* (apply-volume))
    *volume*))

(defun mute (&optional (on t))
  (sb-thread:with-recursive-lock (*audio-lock*)
    (setf *muted* on)
    (when *running* (apply-volume))
    on))

(defun tone-octets (hz seconds level)
  (let* ((frames (round (* 48000 seconds))) (v (make-array (* 4 frames) :element-type '(unsigned-byte 8))))
    (dotimes (i frames v)
      (let ((s (logand #xFFFF (round (* level 32767 (sin (/ (* 2 pi hz i) 48000)))))))
        (setf (aref v (* 4 i)) (ldb (byte 8 0) s) (aref v (+ 1 (* 4 i))) (ldb (byte 8 8) s)
              (aref v (+ 2 (* 4 i))) (ldb (byte 8 0) s) (aref v (+ 3 (* 4 i))) (ldb (byte 8 8) s))))))

(defun play-tone (&key (hz 440) (seconds 0.5) (level 0.3))
  (write-pcm (tone-octets hz seconds level)))

(defun output-pin ()
  (and *path* (list (widget-nid (first *path*)) (pin-device (first *path*)))))

(defun audio-status ()
  (list :codec (and *codec* (format nil "~8,'0x" (codec-vendor *codec*)))
        :pin (output-pin) :running *running* :suspended *suspended*
        :written *written* :played *played* :volume *volume* :muted *muted*))
