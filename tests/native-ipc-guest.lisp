(in-package #:cl-user)
(defun ipc-check (label ok)
  (format t "~&[NATIVE-IPC ~a ~a]~%" label (if ok "PASS" "FAIL"))
  (finish-output)
  (unless ok (error "Native IPC check ~a" label)))
(ipc-check "COMPILE"
  (and (darterfly/cc:compile-c "/Users/darterfly/native-ipc-probe.c" "/tmp/ipc.o"
                               :compat nil)
       (darterfly/cc:compile-c "/usr/src/darterfly/src/libsa/crt0.S" "/tmp/crt0.o"
                               :compat nil)))
(darterfly/cc:link-native-program "/tmp/native-ipc" '("/tmp/crt0.o" "/tmp/ipc.o"))
(let ((p (sb-ext:run-program "/tmp/native-ipc" '("hold") :search nil :wait nil
                             :input :stream :output *standard-output*
                             :error *error-output*)))
  (unwind-protect
       (progn
         (ipc-check "OWN-WORLD"
           (loop repeat 500
                 for proc = (darterfly/bsd:pfind (sb-ext:process-pid p))
                 when (and proc (darterfly/bsd::proc-native-world proc)) return t
                 do (sleep 0.01)))
         (write-char #\G (sb-ext:process-input p))
         (close (sb-ext:process-input p))
         (sb-ext:process-wait p)
         (ipc-check "RUN" (eql 0 (sb-ext:process-exit-code p))))
    (when (eq :running (sb-ext:process-status p)) (sb-ext:process-kill p 9))
    (sb-ext:process-close p)))
(ipc-check "CLEAN"
  (and (zerop (hash-table-count darterfly/bsd::*native-processes*))
       (zerop (hash-table-count darterfly/bsd::*control-buffers*))
       (zerop (hash-table-count darterfly/bsd::*queued-files*))))
(ipc-check "ALIVE" (= 42 (+ 19 23)))

;; Exercise the same service both directly and through a Lisp-world RPC.
(darterfly/install::esp)
(let* ((path "/dev/shm/lisp-shared")
       (fd (sb-posix:open path (logior sb-posix:o-creat sb-posix:o-rdwr) #o600))
       (view nil))
  (unwind-protect
       (progn
         (sb-posix:ftruncate fd 4096)
         (setf view (sb-posix:mmap (sb-sys:int-sap 0) 4096 3 sb-posix:map-shared fd 0))
         (setf (sb-sys:sap-ref-32 view 0) 1234)
         (let* ((code
                  "(let* ((fd (sb-posix:open \"/dev/shm/lisp-shared\" sb-posix:o-rdwr)) (p (sb-posix:mmap (sb-sys:int-sap 0) 4096 3 sb-posix:map-shared fd 0))) (unless (= 1234 (sb-sys:sap-ref-32 p 0)) (error \"shared read\")) (setf (sb-sys:sap-ref-32 p 0) 4321) (sb-posix:close fd) (sb-posix:munmap p 4096) (sb-ext:exit :code 0))")
                (result
                  (darterfly/run:run-world
                    "/Volumes/EFI/EFI/darterfly/gen-1/darterfly.core"
                    (darterfly/run::world-argv code) :cwd "/" :disk t :timeout 120)))
           (ipc-check "LISP-WORLD"
             (and (eql 0 (getf result :exit))
                  (= 4321 (sb-sys:sap-ref-32 view 0))))))
    (when view (sb-posix:munmap view 4096))
    (sb-posix:close fd)
    (sb-posix:unlink path)))

(defvar *ipc-finalized* nil)
(defun ipc-orphan-view ()
  (let* ((path "/dev/shm/orphan-shared")
         (fd (sb-posix:open path (logior sb-posix:o-creat sb-posix:o-rdwr) #o600)))
    (sb-posix:ftruncate fd 4096)
    (let* ((view (sb-posix:mmap (sb-sys:int-sap 0) 4096 3 sb-posix:map-shared fd 0))
           (node (darterfly/bsd::fd-vnode fd)))
      (setf (sb-sys:sap-ref-32 view 0) 1618)
      (sb-ext:finalize node (lambda () (setf *ipc-finalized* t)))
      (sb-posix:unlink path)
      (sb-posix:close fd)
      view)))
;; Dead helper threads leave no conservative stack roots for the vnodes.
(dotimes (round 3)
  (setf *ipc-finalized* nil)
  (let ((view (sb-thread:join-thread
                (sb-thread:make-thread #'ipc-orphan-view :name "orphan owner"))))
    (unwind-protect
         (progn
           (ipc-check "OWNER-RELEASED"
             (loop repeat 250 do (sb-ext:gc :full t) (sleep 0.02)
                   when *ipc-finalized* return t))
           (sleep 0.05)
           (ipc-check "ORPHAN-MAPPING" (= 1618 (sb-sys:sap-ref-32 view 0)))
           (setf (sb-sys:sap-ref-32 view 0) 2718)
           (ipc-check "ORPHAN-WRITE" (= 2718 (sb-sys:sap-ref-32 view 0))))
      (sb-posix:munmap view 4096))))
