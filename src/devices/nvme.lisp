(in-package #:darterfly/devices)

(defconstant +nvme-queue-size+ 64)
(defconstant +nvme-pages+ 8)
;; Keep one submission queue, but give each outstanding command its own DMA.
;; Leave room in the 64-entry hardware ring; no caller owns the completion ring.
(defconstant +nvme-inflight+ 16)

(define-device-class nvme-disk "NVMeBlockStorageDevice" (block-device)
  ((registers :accessor nvme-registers)
   (stride :accessor nvme-stride)
   (vector :initform nil :accessor nvme-vector)
   (msi-x :initform nil :accessor nvme-msi-x)
   (admin :accessor nvme-admin)
   (io :accessor nvme-io)
   ;; Observations live on the updatable device object, not the queue struct.
   (command-queue :initform nil :accessor nvme-command-queue)
   (command-started :initform nil :accessor nvme-command-started)
   (command-opcode :initform nil :accessor nvme-command-opcode)
   (block-count :initform 0 :accessor block-count)
   (lba-size :initform 512 :accessor nvme-lba-size)
   (data :accessor nvme-data)
   (prp-list :accessor nvme-prp-list)
   (buffers :initform nil :accessor nvme-buffers)
   (active :initform 0 :accessor nvme-active)
   (fault :initform nil :accessor nvme-fault)
   (admission :initform nil :accessor nvme-admission)
   (submitted :initform 0 :accessor nvme-submitted)
   (completed :initform 0 :accessor nvme-completed)
   (high-water :initform 0 :accessor nvme-high-water)
   (lock :initform (sb-thread:make-mutex :name "nvme") :reader nvme-lock)))

(add-personality "Class" "NVMeBlockStorageDevice" "ProviderClass" "PCIDevice"
                 "PCIClassMatch" "0x00010802")

(defstruct nvme-queue id sq cq (tail 0) (head 0) (phase 1) (cid 0))

;; A buffer remains controller-owned until its CQ entry is consumed, even if
;; the submitting Lisp thread exits. Reaping copies reads before returning DMA
;; to the pool, so an abandoned caller cannot leak slots or reuse live DMA.
(defstruct nvme-buffer pages prp request)
(defstruct nvme-request opcode vector start bytes started done failure)

(defun nvme-read-32 (n offset) (mmio-read (+ (nvme-registers n) offset) 32))
(defun nvme-write-32 (n offset value) (mmio-write (+ (nvme-registers n) offset) 32 value))
(defun nvme-read-64 (n offset) (logior (nvme-read-32 n offset) (ash (nvme-read-32 n (+ offset 4)) 32)))
(defun nvme-write-64 (n offset value)
  (nvme-write-32 n offset (ldb (byte 32 0) value))
  (nvme-write-32 n (+ offset 4) (ldb (byte 32 32) value)))

(defun nvme-wait-ready (n ready)
  (loop :repeat 20000
        :until (eq ready (logtest (nvme-read-32 n #x1c) 1))
        :do (sleep 0.001)
        :finally (unless (eq ready (logtest (nvme-read-32 n #x1c) 1))
                   (error "nvme: the controller never became ~:[idle~;ready~]" ready))))

(defun zero-page (pa)
  (loop :for at :from 0 :below 4096 :by 8 :do (ml-phys-write-64 (+ pa at) 0)))

(defun nvme-publish (n q cid opcode nsid prp1 prp2 cdw10 cdw11 cdw12)
  (let ((slot (+ (nvme-queue-sq q) (* 64 (nvme-queue-tail q)))))
    (loop :for at :from 0 :below 64 :by 8 :do (ml-phys-write-64 (+ slot at) 0))
    (ml-phys-write-32 slot (logior opcode (ash cid 16)))
    (ml-phys-write-32 (+ slot 4) nsid)
    (ml-phys-write-64 (+ slot 24) prp1)
    (ml-phys-write-64 (+ slot 32) prp2)
    (ml-phys-write-32 (+ slot 40) cdw10)
    (ml-phys-write-32 (+ slot 44) cdw11)
    (ml-phys-write-32 (+ slot 48) cdw12)
    (setf (nvme-queue-tail q) (mod (1+ (nvme-queue-tail q)) +nvme-queue-size+))
    (sb-thread:barrier (:write))
    (nvme-write-32 n (+ #x1000 (* 2 (nvme-queue-id q) (nvme-stride n))) (nvme-queue-tail q))))

(defun nvme-command (n q opcode &key (nsid 0) (prp1 0) (prp2 0) (cdw10 0) (cdw11 0) (cdw12 0))
  ;; A method already on the stack during live reload may still use the old
  ;; synchronous flush entry. It must join the queued path once DMA is pooled.
  (when (and (= (nvme-queue-id q) 1) (= opcode 0) (nvme-buffers n))
    (return-from nvme-command
      (call-outside-nvme-lock n (lambda () (nvme-flush-queued n)))))
  ;; Used for controller setup only; normal I/O uses NVME-SUBMIT-LOCKED.
  (let ((cid (setf (nvme-queue-cid q) (ldb (byte 16 0) (1+ (nvme-queue-cid q))))))
    (setf (nvme-command-queue n) (nvme-queue-id q)
          (nvme-command-opcode n) opcode
          (nvme-command-started n) (get-internal-real-time))
    (nvme-publish n q cid opcode nsid prp1 prp2 cdw10 cdw11 cdw12)
    (let ((entry (+ (nvme-queue-cq q) (* 16 (nvme-queue-head q)))))
      (loop :until (= (ldb (byte 1 16) (ml-phys-read-32 (+ entry 12))) (nvme-queue-phase q))
            :do (if (nvme-vector n)
                    (wait-for-interrupt (list (nvme-vector n)) 0.01)
                    (sb-thread:thread-yield)))
      (sb-thread:barrier (:read))
      (let ((status (ldb (byte 15 17) (ml-phys-read-32 (+ entry 12))))
            (result (ml-phys-read-32 entry)))
        (setf (nvme-queue-head q) (mod (1+ (nvme-queue-head q)) +nvme-queue-size+))
        (when (zerop (nvme-queue-head q))
          (setf (nvme-queue-phase q) (- 1 (nvme-queue-phase q))))
        (nvme-write-32 n (+ #x1000 (* (1+ (* 2 (nvme-queue-id q))) (nvme-stride n))) (nvme-queue-head q))
        (setf (nvme-command-started n) nil)
        (unless (zerop status)
          (error "nvme: command ~x failed with status ~x" opcode status))
        result))))

(defun reset-queue (q)
  (zero-page (nvme-queue-sq q))
  (zero-page (nvme-queue-cq q))
  (setf (nvme-queue-tail q) 0 (nvme-queue-head q) 0 (nvme-queue-phase q) 1)
  q)

(defun make-queue (id)
  (reset-queue (make-nvme-queue :id id :sq (vm-page-grab) :cq (vm-page-grab))))

(defun apst-table (page)
  (let ((table (make-array 32 :initial-element 0)) (target 0))
    (loop for state from (ml-phys-read-8 (+ page 263)) downto 0
          for at = (+ page 2048 (* 32 state))
          do (setf (aref table state) target)
             (when (logbitp 1 (ml-phys-read-8 (+ at 3)))
               (let ((entry (ml-phys-read-32 (+ at 4))) (exit (ml-phys-read-32 (+ at 8))))
                 (when (<= exit 100000)
                   (setf target (logior (ash state 3) (ash (if (<= (+ entry exit) 15000) 100 2000) 8)))))))
    table))

(defun enable-apst (n)
  (let ((page (vm-page-grab)))
    (zero-page page)
    (nvme-command n (nvme-admin n) #x06 :prp1 page :cdw10 1)
    (when (logbitp 0 (ml-phys-read-8 (+ page 265)))
      (let ((table (apst-table page)))
        (zero-page page)
        (dotimes (i 32) (ml-phys-write-64 (+ page (* 8 i)) (aref table i)))
        (nvme-command n (nvme-admin n) #x09 :prp1 page :cdw10 #x0C :cdw11 1)
        t))))

(defun enable-controller (n)
  (setf (nvme-command-started n) nil (nvme-command-queue n) nil
        (nvme-command-opcode n) nil)
  (nvme-write-32 n #x14 0)
  (nvme-wait-ready n nil)
  (when (nvme-msi-x n) (set-msi-x-vector (nvme-msi-x n) 0 (nvme-vector n)))
  (let ((admin (reset-queue (nvme-admin n))) (io (reset-queue (nvme-io n))))
    (nvme-write-32 n #x24 (logior (ash (1- +nvme-queue-size+) 16) (1- +nvme-queue-size+)))
    (nvme-write-64 n #x28 (nvme-queue-sq admin))
    (nvme-write-64 n #x30 (nvme-queue-cq admin))
    (nvme-write-32 n #x14 (logior 1 (ash 6 16) (ash 4 20)))
    (nvme-wait-ready n t)
    (nvme-command n admin #x05 :prp1 (nvme-queue-cq io)
                               :cdw10 (logior (ash (1- +nvme-queue-size+) 16) 1)
                               :cdw11 (logior (if (nvme-vector n) 2 0) 1))
    (nvme-command n admin #x01 :prp1 (nvme-queue-sq io)
                               :cdw10 (logior (ash (1- +nvme-queue-size+) 16) 1)
                               :cdw11 (logior (ash 1 16) 1))
    (ignore-errors (enable-apst n))))

(defmethod start ((n nvme-disk) (d pci-node))
  (let ((map (map-device-memory-with-index d 0)))
    (unless map (return-from start nil))
    (setf (nvme-registers n) (map-virtual-address map)))
  (set-memory-enable d t)
  (set-bus-master-enable d t)
  (let ((cap (nvme-read-64 n 0)))
    (setf (nvme-stride n) (ash 4 (ldb (byte 4 32) cap))))
  (nvme-write-32 n #x14 0)
  (nvme-wait-ready n nil)
  (multiple-value-bind (table entries) (enable-msi-x d)
    (when (and table entries (plusp entries))
      (let ((vector (allocate-vector)))
        (when vector
          (setf (nvme-msi-x n) table (nvme-vector n) vector)))))
  (setf (nvme-admin n) (make-queue 0) (nvme-io n) (make-queue 1))
  (enable-controller n)
  (let ((page (vm-page-grab)))
    (nvme-command n (nvme-admin n) #x06 :nsid 1 :prp1 page :cdw10 0)
    (let* ((format (ldb (byte 4 0) (ml-phys-read-8 (+ page 26))))
           (lbads (ml-phys-read-8 (+ page 128 (* 4 format) 2))))
      (setf (block-count n) (ml-phys-read-64 page)
            (nvme-lba-size n) (ash 1 lbads))))
  (unless (= (nvme-lba-size n) 512)
    (error "nvme: namespace 1 has ~d-byte blocks; only 512 are handled" (nvme-lba-size n)))
  (setf (nvme-data n) (loop :repeat +nvme-pages+ :collect (vm-page-grab))
        (nvme-prp-list n) (vm-page-grab))
  (loop :for pa :in (rest (nvme-data n)) :for at :from 0 :by 8
        :do (ml-phys-write-64 (+ (nvme-prp-list n) at) pa))
  (set-property n "Physical Interconnect" "PCI-Express")
  (register-service n)
  t)

(defun nvme-ensure-buffers (n)
  ;; Called with NVME-LOCK. Reuse the original buffer on live upgrades.
  (unless (nvme-buffers n)
    (setf (nvme-buffers n)
          (coerce
           (cons (make-nvme-buffer :pages (nvme-data n) :prp (nvme-prp-list n))
                 (loop repeat (1- +nvme-inflight+)
                       collect (let ((pages (loop repeat +nvme-pages+ collect (vm-page-grab)))
                                     (prp (vm-page-grab)))
                                 (loop for pa in (rest pages) for at from 0 by 8
                                       do (ml-phys-write-64 (+ prp at) pa))
                                 (make-nvme-buffer :pages pages :prp prp))))
           'vector))))

(defun nvme-reap (n)
  ;; NVME-LOCK protects submission, CQ consumption, and buffer ownership.
  ;; Completions may be out of order: CID, not the current waiting thread,
  ;; identifies the request. No device wait occurs under this mutex.
  (let ((q (nvme-io n)))
    (loop for entry = (+ (nvme-queue-cq q) (* 16 (nvme-queue-head q)))
          for word = (ml-phys-read-32 (+ entry 12))
          while (= (ldb (byte 1 16) word) (nvme-queue-phase q))
          do (sb-thread:barrier (:read))
             (let* ((cid (ldb (byte 16 0) word))
                    (status (ldb (byte 15 17) word))
                    (buffer (and (nvme-buffers n) (< cid (length (nvme-buffers n)))
                                 (aref (nvme-buffers n) cid)))
                    (request (and buffer (nvme-buffer-request buffer))))
               (unless request (error "nvme: unexpected completion CID ~d" cid))
               (sb-sys:without-interrupts
                 (setf (nvme-request-failure request)
                       (handler-case
                           (progn
                             (unless (zerop status)
                               (error "nvme: command ~x failed with status ~x"
                                      (nvme-request-opcode request) status))
                             (when (= (nvme-request-opcode request) 2)
                               (loop for pa in (nvme-buffer-pages buffer)
                                     for at from (nvme-request-start request) by 4096
                                     for left downfrom (nvme-request-bytes request) by 4096
                                     while (plusp left)
                                     do (copy-from-phys pa (nvme-request-vector request) at (min 4096 left))))
                             nil)
                         (error (e) e)))
                 (setf (nvme-request-vector request) nil
                       (nvme-request-done request) t
                       (nvme-buffer-request buffer) nil
                       (nvme-queue-head q) (mod (1+ (nvme-queue-head q)) +nvme-queue-size+))
                 (decf (nvme-active n))
                 (incf (nvme-completed n))
                 (when (zerop (nvme-queue-head q))
                   (setf (nvme-queue-phase q) (- 1 (nvme-queue-phase q))))
                 (nvme-write-32 n (+ #x1000 (* (1+ (* 2 (nvme-queue-id q))) (nvme-stride n)))
                                (nvme-queue-head q)))))))

(defun nvme-submit-locked (n opcode lba count vector start)
  (when (nvme-fault n) (error (nvme-fault n)))
  (nvme-ensure-buffers n)
  (let ((id (position nil (nvme-buffers n) :key #'nvme-buffer-request)))
    (when id
      (let* ((buffer (aref (nvme-buffers n) id))
             (data (nvme-buffer-pages buffer)) (bytes (* count 512))
             (pages (ceiling bytes 4096))
             (request (make-nvme-request :opcode opcode :vector vector :start start
                                        :bytes bytes :started (get-internal-real-time))))
        (when (= opcode 1)
          (loop for pa in data for at from start by 4096
                for left downfrom bytes by 4096 while (plusp left)
                do (copy-to-phys vector at pa (min 4096 left))))
        ;; Publication must not be interrupted between transferring ownership
        ;; and ringing the doorbell. A later caller can reap abandoned requests.
        (sb-sys:without-interrupts
          (setf (nvme-buffer-request buffer) request)
          (incf (nvme-active n))
          (incf (nvme-submitted n))
          (setf (nvme-high-water n) (max (nvme-high-water n) (nvme-active n)))
          (nvme-publish n (nvme-io n) id opcode 1
                        (if (plusp bytes) (first data) 0)
                        (cond ((<= pages 1) 0) ((= pages 2) (second data)) (t (nvme-buffer-prp buffer)))
                        (ldb (byte 32 0) lba) (ldb (byte 32 32) lba) (if (plusp count) (1- count) 0)))
        request))))

(defun nvme-wait-progress (n)
  (if (nvme-vector n)
      (wait-for-interrupt (list (nvme-vector n)) 0.01)
      (sb-thread:thread-yield)))

(defun nvme-await (n requests)
  (let ((deadline (+ (get-internal-real-time) (* 30 internal-time-units-per-second))))
    (loop
      (sb-thread:with-mutex ((nvme-lock n))
        (nvme-reap n)
        (when (every #'nvme-request-done requests)
          (dolist (request requests)
            (when (nvme-request-failure request) (error (nvme-request-failure request))))
          (return)))
      ;; The request remains attached to its DMA slot after timeout. A later
      ;; completion may reclaim it; timeout alone never permits buffer reuse.
      (when (> (get-internal-real-time) deadline)
        (error "nvme: completion timed out; DMA ownership retained"))
      (nvme-wait-progress n))))

(defun call-outside-nvme-lock (n function)
  ;; Preserve the lock contract of pre-upgrade READ/WRITE/FLUSH method frames.
  (if (sb-thread:holding-mutex-p (nvme-lock n))
      (unwind-protect
           (progn (sb-thread:release-mutex (nvme-lock n)) (funcall function))
        (sb-thread:grab-mutex (nvme-lock n)))
      (funcall function)))

(defun nvme-transfer (n opcode lba count vector start)
  (when (sb-thread:holding-mutex-p (nvme-lock n))
    (return-from nvme-transfer
      (call-outside-nvme-lock n (lambda () (nvme-transfer n opcode lba count vector start)))))
  ;; Bound the caller's retained request list as well as the hardware queue.
  ;; A large transfer and independent callers can both keep the controller busy.
  (let ((per (* +nvme-pages+ 8)) (done 0) (requests nil))
    (loop while (< done count)
          do (let ((submitted nil))
               (sb-thread:with-mutex ((nvme-lock n))
                 (nvme-reap n)
                 (unless (nvme-admission n)
                   (loop while (< done count)
                         for amount = (min per (- count done))
                         for request = (nvme-submit-locked n opcode (+ lba done) amount vector (+ start (* done 512)))
                         while request
                         do (push request requests) (incf done amount) (setf submitted t))))
               (when requests (nvme-await n requests) (setf requests nil))
               (unless submitted (nvme-wait-progress n))))))

(defun nvme-close-admission (n reason)
  ;; Returns holding NVME-LOCK with all earlier commands completed. The caller
  ;; must reopen admission/release it. Draining never holds the queue lock.
  (let ((owned nil) (success nil)
        (deadline (+ (get-internal-real-time) (* 30 internal-time-units-per-second))))
    (unwind-protect
         (loop
           (sb-thread:grab-mutex (nvme-lock n))
           (unless (or owned (nvme-admission n))
             (sb-sys:without-interrupts (setf (nvme-admission n) reason owned t)))
           (nvme-reap n)
           (when (and owned (zerop (nvme-active n)))
             (setf success t)
             (return))
           (sb-thread:release-mutex (nvme-lock n))
           (when (> (get-internal-real-time) deadline)
             (error "nvme: cannot drain for ~a; DMA ownership retained" reason))
           (nvme-wait-progress n))
      (unless success
        (unless (sb-thread:holding-mutex-p (nvme-lock n)) (sb-thread:grab-mutex (nvme-lock n)))
        (when owned (setf (nvme-admission n) nil))
        (sb-thread:release-mutex (nvme-lock n))))))

(defun nvme-open-admission (n)
  (setf (nvme-admission n) nil)
  (sb-thread:release-mutex (nvme-lock n)))

(defmethod suspend ((n nvme-disk))
  (nvme-close-admission n :suspend)
  ;; Wake owns reopening admission, including failed suspend preparation.
  (nvme-write-32 n #x14 (logior (logandc2 (nvme-read-32 n #x14) (ash 3 14)) (ash 1 14)))
  (loop repeat 2000 until (= (ldb (byte 2 2) (nvme-read-32 n #x1c)) 2)
        do (sleep 0.001)
        finally (unless (= (ldb (byte 2 2) (nvme-read-32 n #x1c)) 2)
                  (error "nvme: shutdown did not complete"))))

(defmethod wake ((n nvme-disk))
  (when (sb-thread:holding-mutex-p (nvme-lock n))
    (unwind-protect
         (handler-case (progn (enable-controller n) (setf (nvme-fault n) nil))
           (error (e) (setf (nvme-fault n) e) (error e)))
      (nvme-open-admission n))))

(defmethod block-size ((n nvme-disk)) 512)

(defun nvme-check-range (n lba count)
  (unless (and (typep lba '(integer 0)) (typep count '(integer 0))
               (<= lba (block-count n)) (<= count (- (block-count n) lba)))
    (error "nvme: invalid block range ~s + ~s" lba count)))

(defun nvme-flush-queued (n)
  (let ((owned nil))
    (unwind-protect
         (progn
           (nvme-close-admission n :flush)
           (setf owned t)
           (let ((request (nvme-submit-locked n 0 0 0 nil 0)))
             (sb-thread:release-mutex (nvme-lock n))
             (nvme-await n (list request))))
      ;; Also cover interruption just after CLOSE-ADMISSION returns its lock.
      (when (or owned (sb-thread:holding-mutex-p (nvme-lock n)))
        (unless (sb-thread:holding-mutex-p (nvme-lock n)) (sb-thread:grab-mutex (nvme-lock n)))
        (nvme-open-admission n))))
  t)

(defmethod read-blocks ((n nvme-disk) lba count)
  (nvme-check-range n lba count)
  (let ((vector (make-array (* count 512) :element-type '(unsigned-byte 8))))
    (nvme-transfer n 2 lba count vector 0)
    vector))

(defmethod write-blocks ((n nvme-disk) lba vector)
  (unless (zerop (mod (length vector) 512)) (error "nvme: unaligned write length"))
  (let ((count (/ (length vector) 512)))
    (nvme-check-range n lba count)
    (nvme-transfer n 1 lba count vector 0)
    count))

(defmethod flush-blocks ((n nvme-disk)) (nvme-flush-queued n))

(defmethod interrupt-vector ((n nvme-disk)) (nvme-vector n))

(defun nvme-io-status (n)
  (if (sb-thread:grab-mutex (nvme-lock n) :waitp nil)
      (unwind-protect
           (list :fault (and (nvme-fault n) (princ-to-string (nvme-fault n)))
                 :admission (nvme-admission n) :active (nvme-active n)
                 :submitted (nvme-submitted n) :completed (nvme-completed n)
                 :high-water (nvme-high-water n)
                 :pending (loop for buffer across (or (nvme-buffers n) #())
                                for id from 0 for request = (nvme-buffer-request buffer)
                                when request collect (list :cid id :opcode (nvme-request-opcode request)
                                                           :bytes (nvme-request-bytes request)
                                                           :since (nvme-request-started request))))
        (sb-thread:release-mutex (nvme-lock n)))
      (list :busy t :admission (nvme-admission n))))
