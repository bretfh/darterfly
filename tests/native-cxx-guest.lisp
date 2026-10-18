(in-package #:cl-user)
(defun cxx-check (label ok)
  (format t "~&[CXX ~a ~a]~%" label (if ok "PASS" "FAIL"))
  (finish-output)
  (unless ok (error "C++ check ~a failed" label)))
;; The runtime C++ objects are the declared cross seed. Rebuild the shared Low
;; libsa and startup and perform the final executable link in Darterfly.
(assert (darterfly/cc:compile-c "/usr/src/darterfly/src/libsa/crt0.S"
                               "/tmp/cxx-crt0.o" :compat nil))
(darterfly/cc:link-native-program "/tmp/cxx"
  '("/tmp/cxx-crt0.o" "/Users/darterfly/runtime.o" "/Users/darterfly/probe.o"))
(let ((p (sb-ext:run-program "/tmp/cxx" '("/tmp/cxx-artifact") :search nil
                             :output *standard-output* :error *error-output*)))
  (unwind-protect
       (cxx-check "EXIT" (and (eq :exited (sb-ext:process-status p))
                              (eql 42 (sb-ext:process-exit-code p))))
    (sb-ext:process-close p)))
(cxx-check "DESTRUCTION" (string= "TAGZ" (uiop:read-file-string "/tmp/cxx-artifact")))
(let ((p (sb-ext:run-program "/tmp/cxx" '("terminate") :search nil)))
  (unwind-protect (cxx-check "TERMINATE" (eql 77 (sb-ext:process-exit-code p)))
    (sb-ext:process-close p)))
(let ((a (sb-ext:run-program "/tmp/cxx" '("/tmp/cxx-a") :search nil :wait nil))
      (b (sb-ext:run-program "/tmp/cxx" '("/tmp/cxx-b") :search nil :wait nil)))
  (unwind-protect
       (progn
         (sb-ext:process-wait a) (sb-ext:process-wait b)
         (cxx-check "REPEAT" (and (eql 42 (sb-ext:process-exit-code a))
                                  (eql 42 (sb-ext:process-exit-code b))))
         (cxx-check "ISOLATION" (and (string= "TAGZ" (uiop:read-file-string "/tmp/cxx-a"))
                                     (string= "TAGZ" (uiop:read-file-string "/tmp/cxx-b")))))
    (sb-ext:process-close a) (sb-ext:process-close b)))
(cxx-check "CLEAN" (zerop (hash-table-count darterfly/bsd::*native-processes*)))
