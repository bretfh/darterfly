(in-package #:cl-user)

(defparameter *native-bsd-exe* "/Users/darterfly/native-bsd-probe")
(defun bsd-check (label ok)
  (format t "~&[BSD-NATIVE ~a ~a]~%" label (if ok "PASS" "FAIL"))
  (finish-output)
  ok)
(defun bsd-file (path text)
  (with-open-file (s path :direction :output :if-exists :supersede)
    (write-string text s)))
(defun bsd-mode (path)
  (darterfly/vfs:vnop-setattr (darterfly/vfs:namei path) :mode #o755))
(defun bsd-start (mode &optional actions (exe *native-bsd-exe*))
  (darterfly/bsd:posix-spawn exe (list exe mode "source") '("BUILD=native")
                            :file-actions actions))
(defun bsd-wait (pid)
  (loop repeat 500 do
    (multiple-value-bind (found status) (darterfly/bsd:wait4 pid :nohang t)
      (unless (zerop found) (return-from bsd-wait status)))
    (sleep 0.01))
  (darterfly/bsd:kill pid :sigkill)
  (error "Child ~d did not exit" pid))
(defun bsd-error-name (fn)
  (handler-case (progn (funcall fn) nil)
    (darterfly/bsd:errno (e) (darterfly/bsd:errno-name e))))

(bsd-mode *native-bsd-exe*)
(bsd-file "/tmp/native-registered" (format nil "#!darterfly sh~%"))
(bsd-mode "/tmp/native-registered")
(ensure-directories-exist "/tmp/native-work/")
(bsd-file "/tmp/native-work/source" "data")
(bsd-file "/tmp/native-work/shared" "abcdef")
(let* ((parent-cwd (darterfly/bsd:getcwd))
       (fd (darterfly/bsd:open "/tmp/native-work/shared" 0)))
  (unwind-protect
       (progn
         (dolist (to '(8 9 10 11)) (darterfly/bsd:dup2 fd to))
         (darterfly/bsd::with-bsd
           (setf (cdr (aref (darterfly/bsd::proc-fds darterfly/bsd:*proc*) 9)) t
                 (cdr (aref (darterfly/bsd::proc-fds darterfly/bsd:*proc*) 10)) t))
         (darterfly/bsd:read fd 2)
         (let* ((pid (bsd-start
                      "copy"
                      `((:chdir "/tmp/native-work")
                        (:dup2 ,fd 7) (:close ,fd) (:close 8)
                        (:dup2 10 10) (:close 11)
                        (:open 1 "artifact" ,(logior darterfly/bsd:+o-wronly+
                                                   darterfly/bsd:+o-creat+
                                                   darterfly/bsd:+o-trunc+))
                        (:open 2 "diagnostics" ,(logior darterfly/bsd:+o-wronly+
                                                      darterfly/bsd:+o-creat+
                                                      darterfly/bsd:+o-trunc+)))))
                (status (bsd-wait pid)))
           (format t "~&[BSD-NATIVE COPY status ~d]~%" status)
           (bsd-check "COPY-EXIT" (= status (ash 23 8)))
           (bsd-check "ARTIFACT"
                      (string= "cddata" (uiop:read-file-string
                                         "/tmp/native-work/artifact")))
           (let ((ids (darterfly/run::read-octets
                       "/tmp/native-work/diagnostics")))
             (bsd-check "IDENTITY"
                        (and (= (length ids) 8)
                             (= pid (darterfly/bsd::request-u32 ids 0))
                             (= (darterfly/bsd:getpid)
                                (darterfly/bsd::request-u32 ids 4))))))
         (bsd-check "OFFSET" (= 6 (darterfly/bsd:lseek fd 0 :cur)))
         (bsd-check "PARENT-FDS"
                    (and (every (lambda (n)
                                  (not (bsd-error-name
                                        (lambda () (darterfly/bsd:fcntl n 3)))))
                                '(8 9 10 11))
                         (cdr (aref (darterfly/bsd::proc-fds
                                     darterfly/bsd:*proc*) 10))))
         (bsd-check "PARENT-CWD" (string= parent-cwd (darterfly/bsd:getcwd)))
         (bsd-check "CREATED"
                    (string= "built" (uiop:read-file-string
                                      "/tmp/native-work/created"))))
    (dolist (n (list fd 8 9 10 11))
      (ignore-errors (darterfly/bsd:close n)))))

;; Fail before publishing a child. Prepared descriptor references must unwind.
(let ((before (hash-table-count darterfly/bsd::*procs*)))
  (with-open-file (s "/tmp/bad-elf" :direction :output
                     :element-type '(unsigned-byte 8))
    (write-sequence #(127 69 76 70 0 0 0 0) s))
  (bsd-mode "/tmp/bad-elf")
  (bsd-check "BAD-ELF"
             (eq :enoexec (bsd-error-name
                           (lambda () (bsd-start "exit" nil "/tmp/bad-elf")))))
  (bsd-check "BAD-ACTION"
             (eq :ebadf (bsd-error-name
                         (lambda () (bsd-start "exit" '((:dup2 999 1)))))))
  (bsd-check "NO-CHILD-LEAK"
             (= before (hash-table-count darterfly/bsd::*procs*))))
(bsd-check "FAULT" (= 11 (bsd-wait (bsd-start "fault"))))
(bsd-check "MALFORMED" (= 0 (bsd-wait (bsd-start "bad"))))

(multiple-value-bind (a b) (darterfly/bsd:socketpair 1 1)
  (unwind-protect
       (let ((pid (bsd-start "socket" `((:dup2 ,b 0) (:dup2 ,b 1)
                                        (:closefrom 3)))))
         (darterfly/bsd:close b)
         (setf b nil)
         (darterfly/bsd:write a #(112 105 110 103))
         (bsd-check "SOCKET"
                    (and (equalp #(112 105 110 103) (darterfly/bsd:read a 4))
                         (= 0 (bsd-wait pid))))
         (bsd-check "EOF" (equalp #() (darterfly/bsd:read a 1))))
    (ignore-errors (darterfly/bsd:close a))
    (when b (ignore-errors (darterfly/bsd:close b)))))

;; Kill while the process thread is inside a blocking descriptor operation.
(dolist (mode '("read" "poll" "console"))
  (multiple-value-bind (rd wr) (darterfly/bsd:pipe)
    (multiple-value-bind (ready-r ready-w) (darterfly/bsd:pipe)
      (let ((pid nil))
        (unwind-protect
             (progn
               (setf pid (bsd-start (if (string= mode "console") "read" mode)
                                    `((:dup2 ,rd 0) (:dup2 ,ready-w 2)
                                      (:closefrom 3)
                                      ,@(when (string= mode "console")
                                          '((:open 0 "/dev/console" 0))))))
               (darterfly/bsd:close rd) (setf rd nil)
               (darterfly/bsd:close ready-w) (setf ready-w nil)
               (unless (equalp #(114 101 97 100 121)
                               (darterfly/bsd:read ready-r 5))
                 (error "No native ready notification"))
               (sleep 0.05)
               (when (string= mode "read")
                 (bsd-check "NOHANG"
                            (zerop (darterfly/bsd:wait4 pid :nohang t))))
               (darterfly/bsd:kill pid :sigkill)
               (bsd-check (cond ((string= mode "read") "KILL-READ")
                                ((string= mode "poll") "KILL-POLL")
                                (t "KILL-CONSOLE"))
                          (= 9 (bsd-wait pid)))
               (setf pid nil))
          (when pid (ignore-errors (darterfly/bsd:kill pid :sigkill)))
          (dolist (fd (list rd wr ready-r ready-w))
            (when fd (ignore-errors (darterfly/bsd:close fd)))))))))

(let ((pid (bsd-start "loop")))
  (unwind-protect
       (progn
         (loop repeat 100 until (darterfly/bsd::proc-native-world
                                  (darterfly/bsd:pfind pid)) do (sleep 0.01))
         (darterfly/bsd:kill pid :sigstop)
         (multiple-value-bind (found status) (darterfly/bsd:wait4 pid :untraced t)
           (bsd-check "STOP"
                      (and (= found pid) (darterfly/bsd:wifstopped status)
                           (eq :paused
                               (darterfly/worlds:world-state
                                (darterfly/bsd::proc-native-world
                                 (darterfly/bsd:pfind pid)))))))
         (darterfly/bsd:kill pid :sigcont)
         (multiple-value-bind (found status) (darterfly/bsd:wait4 pid :continued t)
           (bsd-check "CONTINUE"
                      (and (= found pid) (darterfly/bsd:wifcontinued status))))
         (darterfly/bsd:kill pid :sigkill)
         (bsd-check "KILL-LOOP" (= 9 (bsd-wait pid))))
    (ignore-errors (darterfly/bsd:kill pid :sigkill))))

(bsd-check "MAP-COALESCE-EXHAUSTION" (= 0 (bsd-wait (bsd-start "map-churn"))))

;; Killing a paused multi-threaded world used to return from sched-ast to
;; user code, where the consumed termination wakeup left it blocked forever.
(dolist (mode '("stop-threads" "churn-threads"))
  (let ((ok t))
    (dotimes (iteration 12)
      (multiple-value-bind (rd wr) (darterfly/bsd:pipe)
        (let ((pid nil) (world nil))
          (unwind-protect
               (progn
                 (setf pid (bsd-start mode `((:dup2 ,wr 2) (:closefrom 3))))
                 (darterfly/bsd:close wr) (setf wr nil)
                 (assert (equalp #(114 101 97 100 121)
                                 (darterfly/bsd:read rd 5)))
                 (setf world (darterfly/bsd::proc-native-world
                              (darterfly/bsd:pfind pid)))
                 (when (evenp iteration)
                   (darterfly/bsd:kill pid :sigstop)
                   (darterfly/bsd:wait4 pid :untraced t))
                 (sleep (* 0.001 (1+ iteration)))
                 (darterfly/bsd:kill pid :sigkill)
                 (unless (and (= 9 (bsd-wait pid))
                              (not (find world (darterfly/worlds:worlds)
                                         :key (lambda (w) (getf w :id)))))
                   (setf ok nil))
                 (setf pid nil))
            (when pid (ignore-errors (darterfly/bsd:kill pid :sigkill)))
            (dolist (fd (list rd wr))
              (when fd (ignore-errors (darterfly/bsd:close fd))))))))
    (bsd-check (if (string= mode "stop-threads")
                   "KILL-PAUSED-THREADS" "KILL-CHURN-THREADS") ok)))

;; Rebuild libsa with Low and the C client with target TCC, then spawn it.
(bsd-check
 "REBUILD"
 (let* ((root "/usr/src/darterfly/")
        (sources '("src/libsa/crt0.S" "tests/native-call.S"
                   "tests/native-bsd-probe.c"))
        (objects
          (loop for source in sources for i from 0
                for out = (format nil "/tmp/native-bsd-~d.o" i)
                do (unless (darterfly/cc:compile-c
                            (concatenate 'string root source) out :compat nil)
                     (error "Cannot compile ~a" source))
                collect (darterfly/link:read-object
                         (darterfly/run::read-octets out) out :user))))
   (with-open-file (s "/tmp/native-bsd-rebuilt" :direction :output
                      :element-type '(unsigned-byte 8))
     (write-sequence
      (darterfly/link:link-native
       (cons (darterfly/link:read-object (darterfly/libsa:libsa-object)
                                        "libsa.o" :user) objects)) s))
   (bsd-mode "/tmp/native-bsd-rebuilt")
   t))
(bsd-check
 "REBUILT-RUN"
 (and (= 0 (bsd-wait
            (bsd-start "socket"
                       `((:open 0 "/tmp/native-work/source" 0)
                         (:open 1 "/tmp/rebuilt-artifact"
                          ,(logior darterfly/bsd:+o-wronly+
                                   darterfly/bsd:+o-creat+))
                         (:closefrom 3))
                       "/tmp/native-bsd-rebuilt")))
      (string= "data" (uiop:read-file-string "/tmp/rebuilt-artifact"))))
;; Lisp build drivers use this path through libsa, rather than BSD directly.
(bsd-check
 "RUN-PROGRAM"
 (let ((process (sb-ext:run-program
                 "/tmp/native-bsd-rebuilt" '("socket") :search nil :wait nil
                 :input #P"/tmp/native-work/source"
                 :output #P"/tmp/sbcl-native-artifact"
                 :error #P"/tmp/sbcl-native-diagnostics"
                 :if-output-exists :supersede :if-error-exists :supersede)))
   (unwind-protect
        (progn
          (unless (loop repeat 500
                        when (eq :exited (sb-ext:process-status process))
                          return t
                        do (sleep 0.01))
            (sb-ext:process-kill process 9)
            (error "RUN-PROGRAM child did not exit"))
          (and (= 0 (sb-ext:process-exit-code process))
               (string= "data"
                        (uiop:read-file-string "/tmp/sbcl-native-artifact"))))
     (sb-ext:process-close process))))
(bsd-check "REPEAT"
           (loop repeat 70 always (= (ash 17 8) (bsd-wait (bsd-start "exit")))))
(bsd-check "ALIVE"
           (and (= 42 (+ 20 22))
                (zerop (hash-table-count darterfly/bsd::*native-processes*))
                (sb-thread:thread-alive-p darterfly/bsd::*native-dispatcher*)))

(dolist (pair `(("NATIVE-CHILDREN" ,*native-bsd-exe*)
                ("REBUILT-CHILDREN" "/tmp/native-bsd-rebuilt")))
  (let ((status (bsd-wait (bsd-start "children" nil (second pair)))))
    (format t "~&[~a child driver status ~d]~%" (first pair) status)
    (bsd-check (first pair) (= 0 status))))

;; The same spawn service is used by an otherwise unchanged isolated SBCL.
(defun child-world (code &optional (timeout 30))
  (darterfly/run:run-world
   "/usr/lib/sbcl/sbcl.core"
   (list "/System/Library/Kernels/kernel" "--core"
         "/System/Library/Kernels/darterfly.core"
         "--no-sysinit" "--no-userinit" "--disable-debugger"
         "--eval" code "--quit")
   :cwd "/" :disk t :timeout timeout))
(bsd-check
 "LISP-CHILDREN"
 (equal '(:exit 0 :files 0)
        (child-world
         "(let ((p (sb-ext:run-program
                    \"/tmp/native-bsd-rebuilt\" '(\"socket\") :search nil
                    :input #P\"/tmp/native-work/source\"
                    :output #P\"/tmp/world-child-artifact\"
                    :error #P\"/tmp/world-child-error\")))
             (assert (= 0 (sb-ext:process-exit-code p)))
             (sb-ext:process-close p))")))
(bsd-check "LISP-ARTIFACT"
           (string= "data" (uiop:read-file-string "/tmp/world-child-artifact")))
(bsd-check
 "LISP-FAULT"
 (equal '(:exit 0 :files 0)
        (child-world
         "(let ((p (sb-ext:run-program \"/tmp/native-bsd-rebuilt\"
                                       '(\"fault\") :search nil)))
             (assert (eq :signaled (sb-ext:process-status p)))
             (assert (= 11 (sb-ext:process-exit-code p)))
             (sb-ext:process-close p))")))
(bsd-check
 "LISP-WAIT-TEARDOWN"
 (let ((result
         (child-world
          "(sb-ext:run-program \"/tmp/native-bsd-rebuilt\"
                               '(\"wait-child\") :search nil
                               :error #P\"/tmp/world-grandchild-pid\")" 5)))
   (and (eq :stopped (getf result :exit))
        (loop for proc being the hash-values of darterfly/bsd::*procs*
              never (darterfly/bsd::proc-world-owner proc))
        (zerop (hash-table-count darterfly/bsd::*native-processes*)))))

(bsd-check
 "LISP-DRIVER"
 (equal '(:exit 0 :files 0)
        (child-world
         "(let ((p (sb-ext:run-program \"/tmp/native-bsd-rebuilt\"
                                       '(\"children\") :search nil
                                       :directory \"/tmp/native-work\")))
             (assert (= 0 (sb-ext:process-exit-code p)))
             (sb-ext:process-close p))")))
(bsd-check
 "LISP-PIPE"
 (equal '(:exit 0 :files 0)
        (child-world
         "(let ((p (sb-ext:run-program \"/tmp/native-bsd-rebuilt\"
                                       '(\"socket\") :search nil :wait nil
                                       :input :stream
                                       :output #P\"/tmp/world-pipe-artifact\")))
             (assert (eq :running (sb-ext:process-status p)))
             (write-string \"data\" (sb-ext:process-input p))
             (finish-output (sb-ext:process-input p))
             (close (sb-ext:process-input p))
             (sb-ext:process-wait p)
             (assert (= 0 (sb-ext:process-exit-code p)))
             (sb-ext:process-close p))")))
(bsd-check "LISP-PIPE-ARTIFACT"
           (string= "data" (uiop:read-file-string "/tmp/world-pipe-artifact")))
(bsd-check
 "LISP-SPAWN-ERROR"
 (equal '(:exit 0 :files 0)
        (child-world
         "(assert (handler-case
                    (progn (sb-ext:run-program \"/does-not-exist\" nil
                                               :search nil) nil)
                    (error () t)))")))
(bsd-check "CHILDREN-CLEAN"
           (and (loop for proc being the hash-values of darterfly/bsd::*procs*
                      never (darterfly/bsd::proc-world-owner proc))
                (zerop (hash-table-count darterfly/bsd::*native-processes*))))

(bsd-check "RUNTIME" (= 0 (bsd-wait (bsd-start "runtime"))))
(bsd-check "REBUILT-RUNTIME"
           (= 0 (bsd-wait (bsd-start "runtime" nil "/tmp/native-bsd-rebuilt"))))
(bsd-mode "/Users/darterfly/native-tls-probe")
(let ((status (bsd-wait (bsd-start "tls" nil "/Users/darterfly/native-tls-probe"))))
  (format t "~&[BSD-NATIVE TLS status ~d]~%" status)
  (bsd-check "TLS-THREADS" (= status 0)))

;; PT_TLS must describe a single bounded template inside a load segment.
(let* ((file (darterfly/run::read-octets "/Users/darterfly/native-tls-probe"))
       (ph (darterfly/link::u file 32 8))
       (count (darterfly/link::u file 56 2))
       (h (loop for i below count for at = (+ ph (* i 56))
                when (= 7 (darterfly/link::u file at 4)) return at)))
  (bsd-check
   "TLS-VALIDATION"
   (and h
        (every
         (lambda (mutation)
           (let ((copy (copy-seq file)))
             (apply #'darterfly/link::put copy mutation)
             (with-open-file (s "/tmp/bad-tls" :direction :output
                                 :element-type '(unsigned-byte 8)
                                 :if-exists :supersede)
               (write-sequence copy s))
             (bsd-mode "/tmp/bad-tls")
             (eq :enoexec
                 (bsd-error-name (lambda () (bsd-start "tls" nil "/tmp/bad-tls"))))))
         (list (list (+ h 8) -1 8) (list (+ h 16) #x1000 8)
               (list (+ h 32) -1 8) (list (+ h 40) 0 8)
               (list (+ h 48) 3 8) (list (+ h 48) (ash 1 21) 8)
               (list ph 7 4))))))

(dolist (alignment '(4 65536))
  (let ((path (format nil "/Users/darterfly/native-tls-~d" alignment)))
    (bsd-mode path)
    (bsd-check (format nil "TLS-~d" alignment)
               (= 0 (bsd-wait (bsd-start "tls" nil path))))))
