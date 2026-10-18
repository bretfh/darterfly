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

(test native-wait-status-matches-the-c-headers
  (is (= #xffff (bsd::native-wait-status (bsd::w-stopcode bsd::+continued+))))
  (is (= #x137f (bsd::native-wait-status (bsd::w-stopcode 17))))
  (is (= 7 (bsd::native-wait-status 10)))
  (is (= 11 (bsd::native-wait-status 11)))
  (is (= (ash 29 8) (bsd::native-wait-status (ash 29 8)))))

(test native-child-requests-are-bounded
  (with-local-process
    (let ((data (make-array 26 :element-type '(unsigned-byte 8)
                              :initial-element 0)))
      (is (= -22 (native-service-result (native-request 15 0 0 #()))))
      (is (= -22 (native-service-result (native-request 15 2 0 data))))
      (bsd::native-put data 0 65)
      (is (= -7 (native-service-result (native-request 15 0 0 data))))
      (bsd::native-put data 0 0)
      (bsd::native-put data 16 1)
      (is (= -22 (native-service-result (native-request 15 0 0 data))))
      (is (= -22 (native-service-result (native-request 16 0 0))))
      (is (= -22 (native-service-result (native-request 16 -1 4))))
      (is (= -10 (native-service-result (native-request 16 1 0))))
      (setf (bsd::proc-closing bsd:*proc*) t)
      (is (= -4 (native-service-result (native-request 15 0 0 data)))))))

(test child-waits-only-reap-the-callers-children
  (with-local-process
    (let* ((bsd::*procs* (make-hash-table))
           (child (make-instance 'bsd:proc :pid 123 :parent bsd:*proc*
                                           :task mach:*task*)))
      (setf (bsd::proc-children bsd:*proc*) (list child)
            (gethash 123 bsd::*procs*) child)
      (is (= 0 (native-service-result (native-request 16 123 1))))
      (let ((bsd:*proc* (make-instance 'bsd:proc :pid 124 :task mach:*task*)))
        (is (= -10 (native-service-result (native-request 16 123 1)))))
      (setf (bsd::proc-state child) :zombie (bsd::proc-status child) (ash 29 8))
      (let ((reply (bsd::with-bsd
                     (bsd::native-service-request (native-request 16 -1 0)))))
        (is (= 123 (bsd::request-u64 reply 0)))
        (is (= (ash 29 8) (bsd::request-u64 reply 8))))
      (is (= -10 (native-service-result (native-request 16 123 0))))
      (is (zerop (hash-table-count bsd::*procs*))))))

(test world-wait-rejects-forged-pointer-layouts
  (with-local-process
    (let ((request (make-array 72 :element-type '(unsigned-byte 8)
                                 :initial-element 0)))
      (bsd::native-put request 8 37)
      (bsd::native-put request 16 -1)
      (flet ((result () (bsd::signed
                        (bsd::request-u64
                         (bsd:serve-request bsd:*proc* request 0) 0))))
        (is (= -22 (result)))
        (setf (aref request 65) 3)
        (bsd::native-put request 52 4 4)
        (is (= -10 (result)))
        (bsd::native-put request 52 4096 4)
        (is (= -22 (result)))))))

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
             (list (list :file "usr/lib/sbcl/sbcl.core"
                         (image::octets (darterfly-file "build/sbcl-mt/output/sbcl.core")))
                   (list :file "Users/darterfly/native-bsd-probe"
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
                                "REBUILD" "REBUILT-RUN" "RUN-PROGRAM" "REPEAT" "ALIVE"
                                "NATIVE-CHILDREN" "REBUILT-CHILDREN"
                                "LISP-CHILDREN" "LISP-ARTIFACT" "LISP-FAULT"
                                "LISP-WAIT-TEARDOWN" "LISP-DRIVER" "LISP-PIPE"
                                "LISP-PIPE-ARTIFACT" "LISP-SPAWN-ERROR"
                                "CHILDREN-CLEAN"))
                 (is (search (format nil "[BSD-NATIVE ~a PASS]" label) output)
                     "BSD native check ~a: ~a" label output))))
        (image:finish c 5)))))
