(in-package #:cl-user)
(defun engine-check (label ok)
  (format t "~&[ENGINE-BOUNDARY ~a ~a]~%" label (if ok "PASS" "FAIL"))
  (finish-output)
  (unless ok (error "Engine boundary ~a" label)))
(engine-check "COMPILE"
  (and (darterfly/cc:compile-c "/Users/darterfly/guest-probe.c" "/tmp/engine.o"
                               :compat nil)
       (darterfly/cc:compile-c "/usr/src/darterfly/src/libsa/crt0.S" "/tmp/crt0.o"
                               :compat nil)))
(darterfly/cc:link-native-program "/tmp/engine-boundary"
                                 '("/tmp/crt0.o" "/tmp/engine.o"))
(let ((p (sb-ext:run-program "/tmp/engine-boundary" nil :search nil
                             :output *standard-output* :error *error-output*)))
  (unwind-protect
       (engine-check "NATIVE-RUNTIME" (eql 0 (sb-ext:process-exit-code p)))
    (sb-ext:process-close p)))
;; Try the actual host harness and actual pinned engine through BSD spawn.
;; Rejection must not publish a process or leave a native world behind.
(dolist (path '("/usr/bin/cef-osr-probe" "/usr/lib/libcef.so"))
  (let ((before (hash-table-count darterfly/bsd::*procs*))
        (rejected nil))
    (handler-case
        (let ((pid (darterfly/bsd:posix-spawn path (list path) nil)))
          (darterfly/bsd:kill pid :sigkill)
          (darterfly/bsd:wait4 pid))
      (darterfly/bsd:errno (condition)
        (format t "~&Engine image rejected: ~a: ~a~%" path condition)
        (setf rejected (eq :enoexec (darterfly/bsd:errno-name condition)))))
    (engine-check (if (search "libcef" path) "CEF-REJECTED" "HOST-EXE-REJECTED")
                  (and rejected (= before (hash-table-count darterfly/bsd::*procs*))))))
(engine-check "CLEAN" (zerop (hash-table-count darterfly/bsd::*native-processes*)))
(engine-check "SUPERVISOR-ALIVE" (= 42 (+ 19 23)))
