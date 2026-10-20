(in-package #:darterfly/test)
(def-suite native-bsd :in host)
(in-suite native-bsd)

(defun service-request (op a b c kinds sizes &optional (payload #()))
  (let ((v (make-array (+ 72 (length payload))
                       :element-type '(unsigned-byte 8) :initial-element 0)))
    (bsd::native-put v 0 1)
    (bsd::native-put v 8 op) (bsd::native-put v 16 a)
    (bsd::native-put v 24 b) (bsd::native-put v 32 c)
    (loop for kind in kinds for size in sizes for i from 0 do
      (setf (aref v (+ 64 i)) kind)
      (bsd::native-put v (+ 48 (* 4 i)) size 4))
    (replace v payload :start1 72)
    v))

(defun service-result (request)
  (bsd::signed (bsd::request-u64 (bsd:serve-request bsd:*proc* request 0) 0)))

(test unified-services-reject-forged-pointers
  (with-local-process
    (is (= -22 (service-result #())))
    (is (= -38 (service-result (service-request 999 0 0 0 '(0 0 0 0) '(0 0 0 0)))))
    (dolist (op '(1 3 4 8 10 19 35 37 48 49 50 51 54 55 56 62 63 64 65))
      (is (= -22 (service-result
                  (service-request op #x1000 #x2000 1 '(0 0 0 0) '(0 0 0 0))))))
    (is (= -22 (service-result
                (service-request 1 1 0 0 '(1 0 0 0) '(2 0 0 0) #(65 66)))))
    (is (= -22 (service-result
                (service-request 1 1 0 0 '(1 0 0 0) '(3 0 0 0) #(0 65 0)))))))

(test shared-services-keep-null-poll-and-bound-resolver-output
  (with-local-process
    (is (= -14 (service-result
                (service-request 50 0 1 0 '(6 0 0 0) '(0 0 0 0)))))
    (let ((q (service-request 48 1 1 1 '(1 3 3 0) '(2 128 32 0) #(65 0))))
      (bsd::native-put q 40 9)
      (is (= -22 (service-result q))))))

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

(test spawn-requests-are-bounded
  (with-local-process
    (let ((data (make-array 26 :element-type '(unsigned-byte 8) :initial-element 0)))
      (flet ((spawn (search)
               (service-result (service-request 51 1 (length data) search
                                                '(2 0 0 0) '(26 0 0 0) data))))
        (is (= -22 (spawn 2)))
        (bsd::native-put data 0 65)
        (is (= -7 (spawn 0)))
        (bsd::native-put data 0 0) (bsd::native-put data 16 1)
        (is (= -22 (spawn 0)))))))

(test child-waits-only-reap-the-callers-children
  (with-local-process
    (let* ((bsd::*procs* (make-hash-table))
           (child (make-instance 'bsd:proc :pid 123 :parent bsd:*proc*
                                           :task mach:*task*)))
      (setf (bsd::proc-children bsd:*proc*) (list child)
            (gethash 123 bsd::*procs*) child)
      (flet ((wait-request (pid options)
               (service-request 37 pid 1 options '(0 3 0 0) '(0 4 0 0))))
        (is (= 0 (service-result (wait-request 123 1))))
        (let ((bsd:*proc* (make-instance 'bsd:proc :pid 124 :task mach:*task*)))
          (is (= -10 (service-result (wait-request 123 1)))))
        (setf (bsd::proc-state child) :zombie (bsd::proc-status child) (ash 29 8))
        (let ((reply (bsd:serve-request bsd:*proc* (wait-request -1 0) 0)))
          (is (= 123 (bsd::request-u64 reply 0)))
          (is (= (ash 29 8) (bsd::request-u32 reply 24))))
        (is (= -10 (service-result (wait-request 123 0))))
        (is (zerop (hash-table-count bsd::*procs*)))))))

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

(defun build-libsa-executable (exe source &key raw-call (tls-alignment 64))
  (let ((objects (list (darterfly/link:read-object
                       (darterfly/libsa:libsa-object) "libsa.o" :user))))
    (loop for source in (append (list "src/libsa/crt0.S" source)
                                (when raw-call (list "tests/native-call.S")))
          for i from 0 for out = (merge-pathnames (format nil "unit-~d.o" i) (uiop:pathname-directory-pathname exe)) do
      (sh "clang" "--target=x86_64-unknown-none-elf" "-c" "-ffreestanding"
          "-fno-stack-protector" "-fno-pie" "-mno-red-zone" "-O1"
          (format nil "-DTLS_ALIGNMENT=~d" tls-alignment)
          "-isystem" (namestring (darterfly-file "src/libsa/include"))
          "-o" (namestring out) (namestring (darterfly-file source)))
      (push (darterfly/link:read-object (image::octets out) (namestring out) :user) objects))
    (with-open-file (s exe :direction :output :if-exists :supersede
                          :element-type '(unsigned-byte 8))
      (write-sequence (darterfly/link:link-native (nreverse objects)) s))))

(test native-bsd-spawn-on-darterfly
  (let* ((dir (scratch))
         (exe (merge-pathnames "native-bsd-probe" dir))
         (tls (merge-pathnames "native-tls-probe" dir))
         (disk (merge-pathnames "native-bsd.img" dir)))
    (build-libsa-executable exe "tests/native-bsd-probe.c" :raw-call t)
    (build-libsa-executable tls "tests/native-tls-probe.c")
    (dolist (alignment '(4 65536))
      (build-libsa-executable
       (merge-pathnames (format nil "native-tls-~d" alignment) dir)
       "tests/native-tls-probe.c" :tls-alignment alignment))
    (image::root-disk
     disk (* 512 1048576)
     (append (image::root-entries)
             (loop for alignment in '(4 65536)
                   for name = (format nil "native-tls-~d" alignment)
                   collect (list :file (concatenate 'string "Users/darterfly/" name)
                                 (image::octets (merge-pathnames name dir))))
             (list (list :file "usr/lib/sbcl/sbcl.core"
                         (image::octets (darterfly-file "build/sbcl-mt/output/sbcl.core")))
                   (list :file "Users/darterfly/native-bsd-probe"
                         (image::octets exe))
                   (list :file "Users/darterfly/native-tls-probe" (image::octets tls))
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
                                "KILL-PAUSED-THREADS" "KILL-CHURN-THREADS" "MAP-COALESCE-EXHAUSTION"
                                "REBUILD" "REBUILT-RUN" "RUN-PROGRAM" "REPEAT" "ALIVE"
                                "NATIVE-CHILDREN" "REBUILT-CHILDREN"
                                "LISP-CHILDREN" "LISP-ARTIFACT" "LISP-FAULT"
                                "LISP-WAIT-TEARDOWN" "LISP-DRIVER" "LISP-PIPE"
                                "LISP-PIPE-ARTIFACT" "LISP-SPAWN-ERROR"
                                "CHILDREN-CLEAN" "RUNTIME" "REBUILT-RUNTIME" "TLS-THREADS" "TLS-4" "TLS-65536" "TLS-VALIDATION"))
                 (is (search (format nil "[BSD-NATIVE ~a PASS]" label) output)
                     "BSD native check ~a: ~a" label output))))
        (image:finish c 5)))))

(in-suite native-bsd)
(test shared-file-request-rejects-untrusted-layouts
  (with-local-process
    (dolist (n '(0 8 24 31 33 64))
      (is (= -22 (service-result
                   (service-request 56 3 1 0 '(0 2 0 0) (list 0 n 0 0)
                     (make-array n :element-type '(unsigned-byte 8) :initial-element 0))))))
    (dolist (op '(54 55))
      (is (= -22 (service-result
                   (service-request op 3 1 1040
                     (if (= op 54) '(0 2 0 0) '(0 6 0 0)) '(0 8 0 0)
                     (make-array 8 :element-type '(unsigned-byte 8) :initial-element 0))))))))

(test exiting-init-and-dead-init-do-not-strand-children
  (dolist (mode '(:self :closing :zombie :live))
    (with-local-process
      (let* ((bsd::*procs* (make-hash-table))
             (init (make-instance 'bsd:proc :pid 1 :parent bsd:*proc0*
                     :task (mach:task-create mach:*task* "test init")))
             (parent (if (eq mode :self) init
                         (make-instance 'bsd:proc :pid 2 :parent bsd:*proc0*
                           :task (mach:task-create mach:*task* "test parent"))))
             (child (make-instance 'bsd:proc :pid 3 :parent parent
                      :task (mach:task-create mach:*task* "test orphan")))
             (reaper (if (eq mode :live) init bsd:*proc0*)))
        (unwind-protect
             (progn
               (setf (gethash 1 bsd::*procs*) init
                     (gethash (bsd::proc-pid parent) bsd::*procs*) parent
                     (gethash 3 bsd::*procs*) child
                     (bsd::proc-children parent) (list child)
                     (bsd::proc-state child) :zombie
                     (bsd::proc-status child) (ash 17 8)
                     (bsd::proc-closing init) (eq mode :closing))
               (when (eq mode :zombie) (setf (bsd::proc-state init) :zombie))
               (bsd::proc-exit parent 0)
               (is (eq reaper (bsd::proc-parent child)))
               (is (null (bsd::proc-children parent)))
               (let ((bsd:*proc* reaper))
                 (multiple-value-bind (pid status) (bsd:wait4 3 :nohang t)
                   (is (= 3 pid))
                   (is (= (ash 17 8) status))))
               (is (null (gethash 3 bsd::*procs*))))
          (mach:task-terminate (bsd::proc-task child))
          (unless (eq parent init) (mach:task-terminate (bsd::proc-task init))))))))
