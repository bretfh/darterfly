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
                     (darterfly/devices::block-count n) 65536
                     (darterfly/devices::nvme-max-transfer n) 32768)
               ;; The real START method initializes the legacy buffer's PRP list.
               (loop for pa in (rest (darterfly/devices::nvme-data n)) for at from 0 by 8
                     do (darterfly/devices::ml-phys-write-64 (+ (darterfly/devices::nvme-prp-list n) at) pa))
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

(test nvme-transfer-size-obeys-identify-and-software-limit
  (is (= 131072 (darterfly/devices::nvme-transfer-size 0 0)))
  (is (= 8192 (darterfly/devices::nvme-transfer-size 1 0)))
  (is (= 32768 (darterfly/devices::nvme-transfer-size 3 0)))
  (is (= 65536 (darterfly/devices::nvme-transfer-size 3 1)))
  (is (= 131072 (darterfly/devices::nvme-transfer-size 9 0)))
  (is (= 131072 (darterfly/devices::nvme-transfer-size 255 15)))
  (signals type-error (darterfly/devices::nvme-transfer-size -1 0)))

(test nvme-large-requests-grow-free-buffers-and-describe-all-pages
  (call-with-nvme-model
   (lambda (n commands complete)
     (declare (ignore complete))
     (setf (darterfly/devices::nvme-max-transfer n) 131072)
     (sb-thread:with-mutex ((darterfly/devices::nvme-lock n))
       (let* ((v (make-array 131072 :element-type '(unsigned-byte 8)))
              (request (darterfly/devices::nvme-submit-locked n 2 0 256 v 0))
              (cmd (first (funcall commands)))
              (b (aref (darterfly/devices::nvme-buffers n) (getf cmd :cid)))
              (slot (darterfly/devices::nvme-queue-sq (darterfly/devices::nvme-io n))))
         (is (= 32 (length (darterfly/devices::nvme-buffer-pages b))))
         (is (= 255 (darterfly/devices::ml-phys-read-32 (+ slot 48))))
         (is (= (darterfly/devices::nvme-buffer-prp b)
                (darterfly/devices::ml-phys-read-64 (+ slot 32))))
         (loop for page in (rest (darterfly/devices::nvme-buffer-pages b)) for at from 0 by 8
               do (is (= page (darterfly/devices::ml-phys-read-64
                                (+ (darterfly/devices::nvme-buffer-prp b) at)))))
         (is (eq request (darterfly/devices::nvme-buffer-request b)))
         (signals error (darterfly/devices::nvme-grow-buffer b 64))
         (signals error (darterfly/devices::nvme-submit-locked n 2 0 257 (make-array 131584) 0)))))))

(test nvme-full-pool-admission-times-out-without-reclaiming-live-dma
  (call-with-nvme-model
   (lambda (n commands complete)
     (declare (ignore complete))
     (sb-thread:with-mutex ((darterfly/devices::nvme-lock n))
       (dotimes (i 16) (darterfly/devices::nvme-submit-locked n 0 0 0 nil 0)))
     (let ((now 0))
       (sb-int:encapsulate 'get-internal-real-time 'admission-clock
         (lambda (&rest args) (declare (ignore args)) now))
       (sb-int:encapsulate 'darterfly/devices::nvme-wait-progress 'admission-clock
         (lambda (&rest args) (declare (ignore args))
           (incf now (* 31 internal-time-units-per-second))))
       (unwind-protect
            (progn
              (signals error (darterfly/devices::read-blocks n 0 1))
              (is (= 16 (length (funcall commands))))
              (is (= 16 (darterfly/devices::nvme-active n)))
              (is (every #'darterfly/devices::nvme-buffer-request (darterfly/devices::nvme-buffers n)))
              (is (not (sb-thread:holding-mutex-p (darterfly/devices::nvme-lock n)))))
         (sb-int:unencapsulate 'get-internal-real-time 'admission-clock)
         (sb-int:unencapsulate 'darterfly/devices::nvme-wait-progress 'admission-clock))))))

(test nvme-buffer-growth-can-retry-after-allocation-failure
  (call-with-nvme-model
   (lambda (n commands complete)
     (declare (ignore commands complete))
     (setf (darterfly/devices::nvme-max-transfer n) 131072)
     (sb-thread:with-mutex ((darterfly/devices::nvme-lock n))
       (darterfly/devices::nvme-ensure-buffers n)
       (let ((b (aref (darterfly/devices::nvme-buffers n) 0)) (allocations 0))
         (sb-int:encapsulate 'darterfly/devices:vm-page-grab 'growth-failure
           (lambda (original)
             (when (= (incf allocations) 3) (error "injected page allocation failure"))
             (funcall original)))
         (unwind-protect
              (signals error (darterfly/devices::nvme-grow-buffer b 32))
           (sb-int:unencapsulate 'darterfly/devices:vm-page-grab 'growth-failure))
         (is (= 10 (length (darterfly/devices::nvme-buffer-pages b))))
         (is (null (darterfly/devices::nvme-buffer-request b)))
         (darterfly/devices::nvme-grow-buffer b 32)
         (loop for page in (rest (darterfly/devices::nvme-buffer-pages b)) for at from 0 by 8
               do (is (= page (darterfly/devices::ml-phys-read-64
                                (+ (darterfly/devices::nvme-buffer-prp b) at))))))))))
