(in-package #:darterfly/test)
(def-suite native-audio :in host)
(in-suite native-audio)

(defmacro with-pcm-test (&body body)
  `(with-io-process
     (let ((darterfly/audio::*pcm-streams* nil)
           (darterfly/audio::*sources* nil)
           (darterfly/audio::*mixer-output* nil)
           (darterfly/audio::*audio-devices* '(:test-device)))
       ,@body)))

(defun open-test-pcm ()
  (bsd::with-bsd
    (bsd::install-vnode
      (darterfly/vfs::install
        (darterfly/vfs::make-file
          :vnode (make-instance 'darterfly/vfs::dev-node :type :vchr :device :audio :mode #o660)
          :flags '(:access :rdwr)))
      (logior 2 bsd::+o-nonblock+))))

(test native-pcm-bounds-wraps-mixes-and-closes
  (with-pcm-test
    (let* ((fd (open-test-pcm)) (duplicate (bsd:dup fd))
           (bytes (make-array 32768 :element-type '(unsigned-byte 8)
                                   :initial-element 10)))
      (is (= 32768 (bsd:write fd bytes)))
      (is (eq :eagain (local-errno (lambda () (bsd:write fd #(0 0 0 0))))))
      (is (equal '(0) (bsd::poll-fds (list (list fd 4)) 0)))
      (is (equalp (subseq bytes 0 4096) (darterfly/audio::mix-period)))
      (is (equal '(4) (bsd::poll-fds (list (list fd 4)) 0)))
      (is (= 4096 (bsd:write fd (make-array 4096 :initial-element 20))))
      (dotimes (i 7) (is (equalp (subseq bytes 0 4096) (darterfly/audio::mix-period))))
      (is (every (lambda (b) (= b 20)) (darterfly/audio::mix-period)))
      (is (eq :einval (local-errno (lambda () (bsd:write fd #(1 2 3))))))
      (bsd:close fd)
      (is (= 1 (length darterfly/audio::*pcm-streams*)))
      (is (= 4 (bsd:write duplicate #(1 2 3 4))))
      (bsd:close duplicate)
      (is (null darterfly/audio::*pcm-streams*))
      (is (zerop (hash-table-count darterfly/vfs::*files*))))))

(test native-pcm-saturates-alongside-lisp-sounds
  (with-pcm-test
    (let ((fd (open-test-pcm)))
      (unwind-protect
           (progn
             (bsd:write fd #(255 127 0 128))
             (setf darterfly/audio::*sources*
                   (list (darterfly/audio::make-source :data #(255 127 0 128))))
             (is (equalp #(255 127 0 128)
                         (subseq (darterfly/audio::mix-period) 0 4))))
        (bsd:close fd)))))

(test closing-native-pcm-wakes-a-blocked-writer
  (with-pcm-test
    (let ((fd (open-test-pcm)) (writer nil))
      (unwind-protect
           (progn
             (bsd:write fd (make-array 32768 :initial-element 0))
             (bsd:fcntl fd 4 0)
             (setf writer (io-worker (lambda ()
                                      (local-errno (lambda () (bsd:write fd #(0 0 0 0)))))))
             (wait-local-syscall bsd:*proc*)
             (bsd:close fd)
             (setf fd nil)
             (is (eq :ebadf (sb-thread:join-thread writer :timeout 3)))
             (is (null darterfly/audio::*pcm-streams*)))
        (when fd (bsd:close fd))
        (when (and writer (sb-thread:thread-alive-p writer))
          (sb-thread:terminate-thread writer))))))

(test native-pcm-reports-pending-frames-and-live-latency-budget
  (with-pcm-test
    (let ((fd (open-test-pcm)))
      (unwind-protect
           (progn
             (is (eq :einval (local-errno (lambda () (bsd:read fd 3)))))
             (is (equalp #(0 0 0 0) (bsd:read fd 4)))
             (bsd:write fd (make-array 4096 :initial-element 0))
             (let ((status (bsd:read fd 8)))
               (is (= 8 (length status)))
               (is (= 1024 (apfs::u32 status 0)))
               (is (= 25600 (apfs::u32 status 4))))
             ;; Removing data from the queue does not make it played: the
             ;; mixer still owns the in-flight period until hardware submit.
             (darterfly/audio::mix-period)
             (is (= 1024 (apfs::u32 (bsd:read fd 4) 0))))
        (bsd:close fd)))))
