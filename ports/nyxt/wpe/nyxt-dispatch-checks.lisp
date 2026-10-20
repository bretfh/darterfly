;;;; Destructive timing probes, staged only in the qualification disk.
(in-package #:nyxt/renderer/wpe)
(defun dispatch-await (thunk)
  (loop repeat 200 when *failure* do (error "Dispatcher failed: ~a" *failure*)
        when (funcall thunk) return t do (sleep .05)
        finally (error "Dispatcher probe timed out")))
(defun dispatch-stats () (j:decode (rpc 19 0)))
(let* ((buffer (nyxt:current-buffer)) (id (native-id buffer))
       (original (symbol-function 'window-call))
       (entered (sb-thread:make-semaphore)) (release (sb-thread:make-semaphore))
       (hold nil) (paused (sb-thread:make-semaphore)))
  (assert (= 4 (length *dispatch-threads*)))
  (unwind-protect
      (progn
        (nyxt:ffi-buffer-evaluate-javascript buffer
          "window.darterTick=0;window.darterTimer=setInterval(()=>{++window.darterTick;document.documentElement.style.backgroundColor='rgb('+(window.darterTick%200)+',47,83)';document.body.style.backgroundColor='transparent'},16);true")
        (dispatch-await (lambda () (> (nyxt:ffi-buffer-evaluate-javascript buffer "window.darterTick") 3)))
        ;; Stall presentation outside the queue lock. Replies must still arrive
        ;; and new frames must replace old pending frames instead of piling up.
        (setf (symbol-function 'window-call)
          (lambda (op view &rest args)
            (when (and (= op 104) (not hold))
              (setf hold t) (sb-thread:signal-semaphore entered)
              (unless (sb-thread:wait-on-semaphore release :timeout 8)
                (error "Presentation probe was not released")))
            (apply original op view args)))
        (assert (sb-thread:wait-on-semaphore entered :timeout 8))
        (let ((before (getf (darterfly/nyxt-work:snapshot *frame-queue*) :coalesced))
              (began (get-internal-real-time)))
          (rpc 18 0)
          (assert (< (- (get-internal-real-time) began) (* 2 internal-time-units-per-second)))
          (sleep 2)
          (let ((stats (darterfly/nyxt-work:snapshot *frame-queue*)))
            (format t "~&Presentation paused: ~s~%" stats)
            (assert (> (getf stats :coalesced) before))
            (assert (<= (getf stats :count) 64))
            (assert (<= (getf stats :bytes) (* 64 1024 1024)))))
        (sb-thread:signal-semaphore release)
        (setf (symbol-function 'window-call) original)
        (format t "~&[NYXT DISPATCH PRESENTATION PASS]~%") (finish-output)
        ;; Pause the actual stream reader. The engine must still process an
        ;; incoming JS command while its output socket has backpressure.
        (let ((before (dispatch-stats)))
          (sb-thread:interrupt-thread *engine-thread*
            (lambda () (sb-thread:signal-semaphore paused) (sleep 3)))
          (assert (sb-thread:wait-on-semaphore paused :timeout 5))
          (engine-send 4 id :data "window.darterPausedAt=Date.now();void 0")
          (sleep 3.3)
          (assert (> (nyxt:ffi-buffer-evaluate-javascript buffer
                       "Date.now()-window.darterPausedAt") 2000))
          (let ((after (dispatch-stats)))
            (format t "~&Engine before: ~s~%Engine after: ~s~%"
              (loop for key being the hash-keys of before using (hash-value value) collect (cons key value))
              (loop for key being the hash-keys of after using (hash-value value) collect (cons key value)))
            (assert (> (gethash "blocked" after) (gethash "blocked" before)))
            (assert (> (gethash "coalesced" after) (gethash "coalesced" before)))
            (assert (<= (gethash "peakFrames" after) 64))
            (assert (<= (gethash "peakFrameBytes" after) (* 64 1024 1024)))))
        (format t "~&[NYXT DISPATCH ENGINE BACKPRESSURE PASS]~%") (finish-output)
        ;; Stop animation with a known final frame; presentation must converge
        ;; to this frame, not replay obsolete frames after the consumer resumes.
        (nyxt:ffi-buffer-evaluate-javascript buffer
          "clearInterval(window.darterTimer);document.documentElement.style.backgroundColor='rgb(19,47,83)';true")
        (dispatch-await
          (lambda ()
            (let ((frame (gethash id (darterfly/nyxt-windows::session-frames *windows*))))
              (when frame
                (let ((pixels (getf frame :pixels)))
                  (and (= 19 (aref pixels 0)) (= 47 (aref pixels 1)) (= 83 (aref pixels 2))))))))
        (assert (= 4 (length *dispatch-threads*)))
        (assert (every #'bt:thread-alive-p *dispatch-threads*))
        (assert (not *failure*))
        (format t "~&[NYXT DISPATCH LATEST FRAME PASS]~%") (finish-output)
        ;; FIFO callbacks may themselves use synchronous RPC; reader progress
        ;; and a fixed worker count must not depend on spawning more workers.
        (let ((seen nil) (done (sb-thread:make-semaphore)))
          (dotimes (i 32)
            (let ((n i))
              (callback-thread id buffer
                (lambda () (rpc 18 0) (push n seen)
                  (when (= n 31) (sb-thread:signal-semaphore done))) 0)))
          (assert (sb-thread:wait-on-semaphore done :timeout 20))
          (assert (equal (reverse seen) (loop for i below 32 collect i))))
        (format t "~&[NYXT DISPATCH ORDERED RPC CALLBACKS PASS]~%")
        (format t "~&[NYXT DISPATCH QUALIFICATION PASS]~%") (finish-output))
    (sb-thread:signal-semaphore release)
    (setf (symbol-function 'window-call) original)
    (ignore-errors (nyxt:ffi-buffer-evaluate-javascript buffer "clearInterval(window.darterTimer);true"))))
