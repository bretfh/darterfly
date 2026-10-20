(in-package #:darterfly/test)

(def-suite nvme-queue :in host)
(in-suite nvme-queue)

;; Model only the hardware interface, not the driver. Tests inspect SQ bytes and
;; inject CQ bytes independently, including completions in reverse order.
(defun call-with-nvme-model (function)
  (let ((memory (make-array (* 2 1024 1024) :element-type '(unsigned-byte 8) :initial-element 0))
        (page 0) (submitted nil) (cq-tail 0) (phase 1)
        (n (make-instance 'darterfly/devices::nvme-disk)))
    (sb-sys:with-pinned-objects (memory)
      (flet ((allocate () (incf page 4096)))
        (sb-int:encapsulate 'darterfly/devices:phys-sap 'nvme-model
          (lambda (f address) (declare (ignore f)) (sb-sys:sap+ (sb-sys:vector-sap memory) address)))
        (sb-int:encapsulate 'darterfly/devices:vm-page-grab 'nvme-model
          (lambda (f) (declare (ignore f)) (allocate)))
        (sb-int:encapsulate 'darterfly/devices::nvme-write-32 'nvme-model
          (lambda (f device offset value)
            (declare (ignore f))
            (when (= offset #x1008)
              (let* ((q (darterfly/devices::nvme-io device))
                     (slot (+ (darterfly/devices::nvme-queue-sq q) (* 64 (mod (1- value) 64))))
                     (word (darterfly/devices::ml-phys-read-32 slot)))
                (push (list :cid (ash word -16) :opcode (logand word 255)
                            :lba (darterfly/devices::ml-phys-read-64 (+ slot 40))
                            :prp (darterfly/devices::ml-phys-read-64 (+ slot 24))) submitted)))))
        (unwind-protect
             (progn
               (setf (darterfly/devices::nvme-stride n) 4
                     (darterfly/devices::nvme-io n) (darterfly/devices::make-queue 1)
                     (darterfly/devices::nvme-data n) (loop repeat 8 collect (allocate))
                     (darterfly/devices::nvme-prp-list n) (allocate)
                     (darterfly/devices::block-count n) 65536)
               (funcall function n
                 (lambda () submitted)
                 (lambda (command &optional (status 0) (byte 0))
                   (let* ((q (darterfly/devices::nvme-io n))
                          (at (+ (darterfly/devices::nvme-queue-cq q) (* cq-tail 16))))
                     (when (= 2 (getf command :opcode))
                       (dotimes (i 512) (setf (aref memory (+ (getf command :prp) i)) byte)))
                     (darterfly/devices::ml-phys-write-32 (+ at 12)
                       (logior (getf command :cid) (ash phase 16) (ash status 17)))
                     (setf cq-tail (mod (1+ cq-tail) 64))
                     (when (zerop cq-tail) (setf phase (- 1 phase)))))))
          (dolist (symbol '(darterfly/devices:phys-sap darterfly/devices:vm-page-grab darterfly/devices::nvme-write-32))
            (sb-int:unencapsulate symbol 'nvme-model)))))))

(test nvme-completions-belong-to-command-ids-and-drain-on-error
  (call-with-nvme-model
   (lambda (n commands complete)
     (let ((a (make-array 512 :element-type '(unsigned-byte 8) :initial-element 0))
           (b (make-array 512 :element-type '(unsigned-byte 8) :initial-element 0)))
       (sb-thread:with-mutex ((darterfly/devices::nvme-lock n))
         (let ((ra (darterfly/devices::nvme-submit-locked n 2 11 1 a 0))
               (rb (darterfly/devices::nvme-submit-locked n 2 12 1 b 0)))
           (is (= 2 (darterfly/devices::nvme-active n)))
           (funcall complete (first (funcall commands)) 0 72)
           (darterfly/devices::nvme-reap n)
           (is (darterfly/devices::nvme-request-done rb))
           (is (not (darterfly/devices::nvme-request-done ra)))
           (is (every (lambda (x) (= x 72)) b))
           (is (every #'zerop a))
           (funcall complete (second (funcall commands)) 2)
           (darterfly/devices::nvme-reap n)
           (is (typep (darterfly/devices::nvme-request-failure ra) 'error))
           (is (zerop (darterfly/devices::nvme-active n)))
           (is (every (lambda (buffer) (null (darterfly/devices::nvme-buffer-request buffer)))
                      (darterfly/devices::nvme-buffers n)))))))))

(test nvme-capacity-and-phase-wrap-do-not-reuse-live-dma
  (call-with-nvme-model
   (lambda (n commands complete)
     (sb-thread:with-mutex ((darterfly/devices::nvme-lock n))
       (dotimes (round 10)
         (dotimes (i 16)
           (is (not (null (darterfly/devices::nvme-submit-locked n 0 i 0 nil 0)))))
         (is (null (darterfly/devices::nvme-submit-locked n 0 99 0 nil 0)))
         (let ((batch (subseq (funcall commands) 0 16)))
           (is (= 16 (length (remove-duplicates batch :key (lambda (x) (getf x :cid))))))
           (dolist (command batch) (funcall complete command)))
         (darterfly/devices::nvme-reap n)
         (is (zerop (darterfly/devices::nvme-active n))))
       (is (= 160 (darterfly/devices::nvme-completed n)))
       (is (= 16 (darterfly/devices::nvme-high-water n)))))))

(test nvme-abandoned-caller-leaves-request-owned-until-completion
  (call-with-nvme-model
   (lambda (n commands complete)
     (let ((submitted (sb-thread:make-semaphore)) (thread nil))
       (unwind-protect
            (progn
              (setf thread
                    (sb-thread:make-thread
                     (lambda ()
                       (sb-thread:with-mutex ((darterfly/devices::nvme-lock n))
                         (darterfly/devices::nvme-submit-locked n 0 0 0 nil 0))
                       (sb-thread:signal-semaphore submitted)
                       (sleep 30))))
              (is (sb-thread:wait-on-semaphore submitted :timeout 2))
              (sb-thread:terminate-thread thread)
              (sb-thread:join-thread thread :default nil)
              (is (= 1 (darterfly/devices::nvme-active n)))
              (sb-thread:with-mutex ((darterfly/devices::nvme-lock n))
                (funcall complete (first (funcall commands)))
                (darterfly/devices::nvme-reap n)
                (is (zerop (darterfly/devices::nvme-active n)))))
         (when (and thread (sb-thread:thread-alive-p thread)) (sb-thread:terminate-thread thread)))))))

(test nvme-flush-gates-new-commands-and-waits-for-old-ones
  (call-with-nvme-model
   (lambda (n commands complete)
     (let ((thread nil) (result nil))
       (sb-thread:with-mutex ((darterfly/devices::nvme-lock n))
         (darterfly/devices::nvme-submit-locked n 1 7 1
           (make-array 512 :element-type '(unsigned-byte 8) :initial-element 77) 0))
       (unwind-protect
            (progn
              (setf thread (sb-thread:make-thread (lambda () (setf result (darterfly/devices::flush-blocks n)))))
              (loop repeat 200 until (eq :flush (darterfly/devices::nvme-admission n)) do (sleep .001))
              (is (eq :flush (darterfly/devices::nvme-admission n)))
              (is (= 1 (length (funcall commands))) "flush cannot reach hardware before the write completes")
              (sb-thread:with-mutex ((darterfly/devices::nvme-lock n))
                (funcall complete (first (funcall commands))))
              (loop repeat 200 until (= 2 (length (funcall commands))) do (sleep .001))
              (is (= 0 (getf (first (funcall commands)) :opcode)))
              (is (null result))
              (sb-thread:with-mutex ((darterfly/devices::nvme-lock n))
                (funcall complete (first (funcall commands))))
              (sb-thread:join-thread thread :timeout 2)
              (is (eq t result))
              (is (null (darterfly/devices::nvme-admission n))))
         (when (and thread (sb-thread:thread-alive-p thread))
           (sb-thread:terminate-thread thread) (sb-thread:join-thread thread :default nil)))))))

(test a-pre-upgrade-driver-frame-releases-and-regains-its-lock
  (let ((n (make-instance 'darterfly/devices::nvme-disk)))
    (sb-thread:with-mutex ((darterfly/devices::nvme-lock n))
      (signals error
        (darterfly/devices::call-outside-nvme-lock n
          (lambda ()
            (is (not (sb-thread:holding-mutex-p (darterfly/devices::nvme-lock n))))
            (error "failed completion"))))
      (is (sb-thread:holding-mutex-p (darterfly/devices::nvme-lock n))))))
