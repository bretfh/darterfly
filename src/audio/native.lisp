;;;; Native PCM endpoint: 48 kHz, stereo, signed 16-bit little endian.
;;;; Each open owns a bounded queue in the existing mixer, released by the
;;;; normal BSD descriptor/world lifecycle. No second hardware driver.
(in-package #:darterfly/audio)

(defclass native-output (darterfly/bsd::vnode)
  ((stream :initarg :stream :reader native-stream)))

(defmethod darterfly/bsd::make-device-file ((device (eql :audio)) fd flags)
  (when (zerop (logand flags 3)) (darterfly/bsd::fail :eacces))
  (unless (default-output-device) (darterfly/bsd::fail :enodev))
  (let* ((stream (make-pcm-stream))
         (file (make-instance 'native-output :fd fd :stream stream :device t
                 :access (logand flags 3)
                 :flags (logand flags darterfly/bsd::+o-nonblock+))))
    (sb-thread:with-mutex (*mixer-lock*) (push stream *pcm-streams*))
    file))

(defmethod darterfly/bsd::file-write ((file native-output) octets)
  (let ((stream (native-stream file)) (count (length octets)))
    (when (plusp (mod count 4)) (darterfly/bsd::fail :einval))
    (when (zerop count) (return-from darterfly/bsd::file-write 0))
    (labels ((write-some ()
               (sb-thread:with-mutex (*mixer-lock*)
                 (when (pcm-stream-closed stream) (darterfly/bsd::fail :ebadf))
                 (when (pcm-stream-failure stream) (darterfly/bsd::fail :eio))
                 (let ((n (min count (- +pcm-capacity+ (pcm-stream-count stream)))))
                   (when (plusp n)
                     (let* ((at (pcm-stream-write-at stream))
                            (first (min n (- +pcm-capacity+ at))))
                       (replace (pcm-stream-data stream) octets
                                :start1 at :end2 first)
                       (when (< first n)
                         (replace (pcm-stream-data stream) octets
                                  :start2 first :end2 n)))
                     (setf (pcm-stream-write-at stream)
                           (mod (+ (pcm-stream-write-at stream) n) +pcm-capacity+))
                     (incf (pcm-stream-count stream) n)
                     (sb-thread:condition-broadcast *mixer-wake*)
                     n)))))
      (or (write-some)
          (if (darterfly/bsd::nonblocking-p file)
              (darterfly/bsd::fail :eagain)
              (darterfly/bsd::sleep-until #'write-some))))))

(defmethod darterfly/bsd::file-read ((file native-output) count)
  ;; Query pending PCM frames. Four bytes, little endian; no blocking.
  (when (< count 4) (darterfly/bsd::fail :einval))
  (let ((result (make-array 4 :element-type '(unsigned-byte 8)))
        (bytes 0) (end 0) (generation 0))
    (sb-thread:with-mutex (*mixer-lock*)
      (let ((s (native-stream file)))
        (setf bytes (+ (pcm-stream-count s) (pcm-stream-in-flight s))
              end (pcm-stream-submitted-end s)
              generation (pcm-stream-generation s))))
    (when *mixer-output*
      (let ((o *mixer-output*))
        (sb-thread:with-recursive-lock ((hda-lock (output-controller o)))
          (when (and (output-running-p o) (= generation (output-generation o)))
            (update-played o)
            ;; Other applications may keep the device busy after this stream
            ;; ends. Its clock counts only through its own last submitted frame.
            (incf bytes (max 0 (- end (output-played o))))))))
    (dotimes (i 4 result)
      (setf (aref result i) (ldb (byte 8 (* i 8)) (floor bytes 4))))))

(defmethod darterfly/bsd::file-poll ((file native-output))
  (sb-thread:with-mutex (*mixer-lock*)
    (let ((s (native-stream file)))
      (cond ((pcm-stream-closed s) #x10)
            ((pcm-stream-failure s) #x8)
            (t (logior 1 (if (< (pcm-stream-count s) +pcm-capacity+) 4 0)))))))

(defmethod darterfly/bsd::file-close ((file native-output))
  (sb-thread:with-mutex (*mixer-lock*)
    (let ((s (native-stream file)))
      (setf (pcm-stream-closed s) t (pcm-stream-count s) 0
            (pcm-stream-in-flight s) 0
            *pcm-streams* (remove s *pcm-streams*))))
  (call-next-method))
