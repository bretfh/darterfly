(in-package #:darterfly/test)
(def-suite native-bsd :in host)
(in-suite native-bsd)

(defun native-request (op a b &optional (data #()))
  (let ((v (make-array (+ 32 (length data))
                       :element-type '(unsigned-byte 8) :initial-element 0)))
    (bsd::native-put v 0 bsd::+native-service-magic+)
    (bsd::native-put v 8 op) (bsd::native-put v 16 a)
    (bsd::native-put v 24 b)
    (replace v data :start1 32)
    v))

(defun native-service-result (v)
  (bsd::with-bsd
    (bsd::signed (bsd::request-u64 (bsd::native-service-request v) 0))))

(test native-services-bound-untrusted-requests
  (with-local-process
    (is (= -22 (native-service-result #())))
    (is (= -22 (native-service-result (make-array 31 :initial-element 0))))
    (is (= -22 (native-service-result
                (make-array 5000 :initial-element 0))))
    (is (= -38 (native-service-result (native-request 999 0 0))))
    (is (= -22 (native-service-result (native-request 1 0 0 #(65 66)))))
    (is (= -22 (native-service-result (native-request 1 0 0 #(0 65 0)))))
    (is (= -22 (native-service-result (native-request 1 0 0 #(255 0)))))
    (is (= -22 (native-service-result (native-request 3 0 -1))))
    (is (= -22 (native-service-result (native-request 11 257 -1))))
    (is (= -22 (native-service-result (native-request 11 1 0 #(0)))))
    (is (= -9 (native-service-result (native-request 7 0 -1))))
    (is (= -9 (native-service-result (native-request 2 -1 0))))))

(test native-descriptors-share-description-not-close-flags
  (with-local-process
    (multiple-value-bind (rd wr) (bsd:pipe)
      (let* ((copy (native-service-result (native-request 6 wr 0)))
             (setflag (native-request 8 copy 2 #(1 0 0 0 0 0 0 0))))
        (is (= 0 (native-service-result setflag)))
        (is (= 1 (native-service-result
                  (native-request 8 copy 1 #(0 0 0 0 0 0 0 0)))))
        (is (= 0 (native-service-result
                  (native-request 8 wr 1 #(0 0 0 0 0 0 0 0)))))
        (is (= 2 (native-service-result (native-request 4 copy 0 #(1 2)))))
        (is (equalp #(1 2) (bsd:read rd 2)))
        (is (= 0 (native-service-result (native-request 2 copy 0))))
        (is (= 1 (bsd:write wr #(3))))
        (bsd:close wr)
        (is (equalp #(3) (bsd:read rd 2)))
        (is (equalp #() (bsd:read rd 1)))))))

(test failed-spawn-actions-unwind-fds-and-child-records
  (with-local-process
    (let ((bsd::*procs* (make-hash-table)) (bsd::*next-pid* 0))
      (multiple-value-bind (rd wr) (bsd:pipe)
        (let ((file (bsd::fd-file wr)))
          (is (eq :ebadf
                  (local-errno
                   (lambda () (bsd:posix-spawn
                               "/unused" nil nil
                               :file-actions `((:dup2 ,wr 10)
                                               (:dup2 999 1)))))))
          (is (= 1 (bsd::file-refs file)))
          (is (zerop (hash-table-count bsd::*procs*)))
          (is (null (bsd::proc-children bsd:*proc*)))
          (bsd:close wr)
          (is (equalp #() (bsd:read rd 1))))))))

(in-suite guest)

(test native-executables-on-darterfly
  (let* ((dir (scratch))
         (exe (merge-pathnames "native-probe" dir))
         (disk (merge-pathnames "native.img" dir)))
    (sh "clang" "--target=x86_64-unknown-none-elf" "-fuse-ld=lld"
        "-nostdlib" "-static" "-fno-stack-protector" "-fno-pie"
        "-mno-red-zone" "-O1" "-Wl,-z,separate-code"
        "-o" (namestring exe)
        (namestring (darterfly-file "tests/native-start.S"))
        (namestring (darterfly-file "tests/native-probe.c")))
    (image::root-disk
     disk (* 512 1048576)
     (append (image::root-entries)
             (loop for name in '("native-start.S" "native-probe.c"
                                 "native-guest.lisp")
                   collect (list :file (concatenate 'string "Users/darterfly/" name)
                                 (image::octets
                                  (darterfly-file
                                   (concatenate 'string "tests/" name)))))
             (list (list :file "Users/darterfly/native-probe" (image::octets exe)))))
    (let* ((image::*console-log-directory*
             (merge-pathnames "native-console/" dir))
           (c (image:bare-console :root disk)))
      (unwind-protect
           (progn
             (image:expect c "* " :timeout 120)
             (image:send c "(load \"/Users/darterfly/native-guest.lisp\")")
             (let ((output (image:expect c (list (format nil "~%* ")
                                                   "debugger invoked")
                                         :timeout 240)))
               (with-open-file (s (merge-pathnames "native-guest.log" image:*build*)
                                  :direction :output :if-exists :supersede)
                 (write-string output s))
               (dolist (label '("HOST-ELF" "PORT" "ZERO-EXIT" "ILLEGAL" "FAULT" "TEXT" "STACK"
                                "NOHANG" "TIMEOUT" "KILL" "DOUBLE-WAIT"
                                "BAD-ELF" "REBUILD" "REBUILT-ELF"
                                "STATUS-LIMIT" "REAP-ALL" "RECLAIM" "ALIVE"))
                 (is (search (format nil "[NATIVE ~a PASS]" label) output)
                     "native guest check ~a: ~a" label output))))
        (image:finish c 5)))))

(test native-bsd-spawn-on-darterfly
  (let* ((dir (scratch))
         (exe (merge-pathnames "native-bsd-probe" dir))
         (disk (merge-pathnames "native-bsd.img" dir)))
    (sh "clang" "--target=x86_64-unknown-none-elf" "-fuse-ld=lld"
        "-nostdlib" "-static" "-ffreestanding" "-fno-stack-protector"
        "-fno-pie" "-mno-red-zone" "-O1" "-Wl,-z,separate-code"
        "-isystem" (namestring (darterfly-file "src/libsa/include"))
        "-o" (namestring exe)
        (namestring (darterfly-file "src/native/start.S"))
        (namestring (darterfly-file "src/native/io.c"))
        (namestring (darterfly-file "tests/native-bsd-probe.c")))
    (image::root-disk
     disk (* 512 1048576)
     (append (image::root-entries)
             (list (list :file "Users/darterfly/native-bsd-probe"
                         (image::octets exe))
                   (list :file "Users/darterfly/native-bsd-guest.lisp"
                         (image::octets
                          (darterfly-file "tests/native-bsd-guest.lisp"))))))
    (let* ((image::*console-log-directory*
             (merge-pathnames "native-bsd-console/" dir))
           (c (image:bare-console :root disk)))
      (unwind-protect
           (progn
             (image:expect c "* " :timeout 120)
             (image:send c "(load \"/Users/darterfly/native-bsd-guest.lisp\")")
             (let ((output (image:expect c (list (format nil "~%* ")
                                                 "debugger invoked")
                                         :timeout 240)))
               (when (search "debugger invoked" output)
                 (setf output (concatenate 'string output
                                          (image:expect c "0] " :timeout 10))))
               (with-open-file (s (merge-pathnames "native-bsd-guest.log"
                                                   image:*build*)
                                  :direction :output :if-exists :supersede)
                 (write-string output s))
               (dolist (label '("COPY-EXIT" "ARTIFACT" "IDENTITY" "OFFSET"
                                "PARENT-FDS" "PARENT-CWD" "CREATED"
                                "BAD-ELF" "BAD-ACTION" "NO-CHILD-LEAK"
                                "FAULT" "MALFORMED" "SOCKET" "EOF"
                                "KILL-READ" "KILL-POLL" "KILL-CONSOLE" "NOHANG"
                                "STOP" "CONTINUE" "KILL-LOOP"
                                "REBUILD" "REBUILT-RUN" "RUN-PROGRAM" "REPEAT" "ALIVE"))
                 (is (search (format nil "[BSD-NATIVE ~a PASS]" label) output)
                     "BSD native check ~a: ~a" label output))))
        (image:finish c 5)))))
