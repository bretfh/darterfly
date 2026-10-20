(in-package #:darterfly/nrepl)

(defun short-name (name)
  (and name (subseq name 0 (min 160 (length name)))))

(defun thread-name (thread)
  (and (typep thread 'sb-thread:thread) (short-name (sb-thread:thread-name thread))))

(defun lock-state (lock)
  (when (typep lock 'sb-thread:mutex)
    (list :name (short-name (sb-thread:mutex-name lock))
          :owner (thread-name (sb-thread:mutex-owner lock)))))

(defun diagnostic-threads ()
  (loop for thread in (sb-thread:list-all-threads) for i below 256
        for waiting = (sb-thread::thread-waiting-for thread)
        collect (list :name (thread-name thread)
                      :wait (if (typep waiting 'sb-thread:mutex) (lock-state waiting)
                                (and waiting :other)))))

(defun diagnostic-locks ()
  (loop for (package name) in darterfly/bsd::*system-locks*
        for symbol = (and (find-package package) (find-symbol name package))
        for lock = (and symbol (boundp symbol) (symbol-value symbol))
        when (typep lock 'sb-thread:mutex) collect (lock-state lock)))

(defun diagnostic-ring ()
  ;; Stateless read of the kernel ring: no logger lock, disk flush or cursor
  ;; mutation. A concurrent writer may overtake this best-effort snapshot.
  (let* ((position (darterfly/log::machdep 69))
         (n (min position 8192))
         (bytes (make-array n :element-type '(unsigned-byte 8))))
    (sb-sys:with-pinned-objects (bytes)
      (darterfly/log::machdep 69 (ldb (byte 32 0) (- position n))
                             (sb-sys:sap-int (sb-sys:vector-sap bytes)) n))
    (list :epoch (darterfly/log::machdep 70) :position position
          :text (sb-ext:octets-to-string bytes :external-format '(:utf-8 :replacement #\?)))))

(defun diagnostic-nvme ()
  (loop for n in (and darterfly/devices:*registry-root*
                       (darterfly/devices:find-entries 'darterfly/devices::nvme-disk))
        for i below 8
        collect (list :name (darterfly/devices:entry-name n)
                      :lock (lock-state (darterfly/devices::nvme-lock n))
                      :queues (loop for slot in '(darterfly/devices::admin darterfly/devices::io)
                                    when (slot-boundp n slot)
                                    collect (let ((q (slot-value n slot)))
                                              (list :id (darterfly/devices::nvme-queue-id q)
                                                    :submitted (darterfly/devices::nvme-queue-cid q)
                                                    :head (darterfly/devices::nvme-queue-head q)
                                                    :tail (darterfly/devices::nvme-queue-tail q)
                                                    :pending-since
                                                    (and (fboundp 'darterfly/devices::nvme-command-started)
                                                         (eql (darterfly/devices::nvme-command-queue n)
                                                              (darterfly/devices::nvme-queue-id q))
                                                         (darterfly/devices::nvme-command-started n))
                                                    :opcode
                                                    (and (fboundp 'darterfly/devices::nvme-command-opcode)
                                                         (eql (darterfly/devices::nvme-command-queue n)
                                                              (darterfly/devices::nvme-queue-id q))
                                                         (darterfly/devices::nvme-command-opcode n))))))))

(defmacro diagnostic-part (&body body)
  `(handler-case (progn ,@body)
     (error (e) (list :unavailable (short-name (princ-to-string e))))))

(defun diagnostic-snapshot ()
  ;; Cached state only. No ping, device register access or filesystem operation.
  ;; Fields are observations, not an atomic system-wide snapshot. Partial data
  ;; remains useful on a damaged system or while loading diagnostics into an
  ;; older live image which lacks some of the optional instrumentation.
  (list :version 1 :time (get-universal-time) :ticks (get-internal-real-time)
        :heap (sb-kernel:dynamic-usage) :gc-time sb-ext:*gc-run-time*
        :locks (diagnostic-part (diagnostic-locks))
        :threads (diagnostic-part (diagnostic-threads))
        :services (diagnostic-part (darterfly/init::diagnostic-jobs))
        :device-transition (diagnostic-part darterfly/devices::*device-transition*)
        :device-last-failure (diagnostic-part darterfly/devices::*device-last-failure*)
        :network (diagnostic-part (darterfly/wifi:network-status))
        :wifi-events (diagnostic-part
                      (loop for event in (and darterfly/wifi::*card*
                                               (darterfly/wifi::card-log darterfly/wifi::*card*))
                            for i below 12 collect event))
        :nvme (diagnostic-part (diagnostic-nvme))
        :kernel (diagnostic-part (darterfly/stats::kernel-times))
        :ring (diagnostic-part (diagnostic-ring))))

(defun diagnostic-text ()
  (let* ((*print-length* 256) (*print-level* 10) (*print-circle* t)
         (text (prin1-to-string (diagnostic-snapshot))))
    ;; nREPL startup historically prints its key into the kernel ring.
    (if (and *key* (plusp (length *key*)))
        (with-output-to-string (out)
          (loop with at = 0 for next = (search *key* text :start2 at)
                do (write-string text out :start at :end next)
                if next do (write-string "[redacted]" out) (setf at (+ next (length *key*)))
                else do (return)))
        text)))
