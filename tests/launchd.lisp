(in-package #:finch/test)

(def-suite launchd :in all)
(in-suite launchd)

(bsd:define-program "finch-test-echo" (argv envp)
  (let ((port (launchd:bootstrap-check-in "finch.test.echo")))
    (let ((m (mach:mach-msg-receive port :timeout 5000)))
      (mach:mach-msg-send (mach:make-message :remote-port (mach:msgh-remote-port m)
                                             :remote-disposition :move-send-once
                                             :body (reverse (mach:msgh-body m)))))
    0))

(bsd:define-program "finch-test-client" (argv envp)
  (let ((port (launchd:bootstrap-look-up "finch.test.echo"))
        (reply (mach:mach-reply-port)))
    (mach:mach-msg-send (mach:make-message :remote-port port :local-port reply :body "finch"))
    (format t "~a~%" (mach:msgh-body (mach:mach-msg-receive reply :timeout 5000)))
    (multiple-value-bind (port kr) (launchd:bootstrap-look-up "finch.test.nobody")
      (format t "~a ~a~%" port kr))
    (multiple-value-bind (port kr) (launchd:bootstrap-check-in "finch.test.echo")
      (format t "~a ~a~%" port kr))
    0))

(bsd:define-program "finch-test-again" (argv envp)
  (format t "x")
  3)

(defun job-plist (path &rest pairs)
  (let ((job (make-hash-table :test 'equal)))
    (loop :for (k v) :on pairs :by #'cddr :do (setf (gethash k job) v))
    (with-open-file (s path :direction :output :if-exists :supersede)
      (plist:write-plist job s))))

(defun wait-for-file (path test &optional (seconds 10))
  (loop :repeat (* seconds 20)
        :for text := (and (probe-file path) (uiop:read-file-string path))
        :when (and text (funcall test text)) :return text
        :do (sleep 0.05)
        :finally (return text)))

(test launchd-runs-jobs
  (let* ((root (uiop:ensure-directory-pathname
                (sb-posix:mkdtemp (format nil "~a/root.XXXXXX" (string-right-trim "/" (uiop:native-namestring (scratch)))))))
         (daemons (merge-pathnames "Library/LaunchDaemons/" root)))
    (ensure-directories-exist daemons)
    (let ((null (merge-pathnames "dev/null" root)))
      (ensure-directories-exist null)
      (with-open-file (s null :direction :output :if-exists :supersede)))
    (loop :for (path program) :in '(("sbin/launchd" "launchd") ("bin/launchctl" "launchctl")
                                    ("usr/libexec/echo" "finch-test-echo") ("usr/libexec/client" "finch-test-client")
                                    ("usr/libexec/again" "finch-test-again"))
          :do (let ((file (merge-pathnames path root)))
                (ensure-directories-exist file)
                (with-open-file (s file :direction :output :if-exists :supersede)
                  (format s "#!finch ~a~%" program))
                (sb-posix:chmod (uiop:native-namestring file) #o755)))
    (let ((services (make-hash-table :test 'equal)))
      (setf (gethash "finch.test.echo" services) t)
      (job-plist (merge-pathnames "echo.plist" daemons) "Label" "finch.test.echo"
                 "Program" "/usr/libexec/echo" "MachServices" services))
    (job-plist (merge-pathnames "client.plist" daemons) "Label" "finch.test.client"
               "ProgramArguments" (vector "/usr/libexec/client") "RunAtLoad" t "StandardOutPath" "/out")
    (job-plist (merge-pathnames "again.plist" daemons) "Label" "finch.test.again"
               "Program" "/usr/libexec/again" "KeepAlive" t "ThrottleInterval" 1 "StandardOutPath" "/again")
    (job-plist (merge-pathnames "missing.plist" daemons) "Label" "finch.test.missing"
               "Program" "/usr/libexec/missing" "RunAtLoad" t)
    (job-plist (merge-pathnames "list.plist" daemons) "Label" "finch.test.list"
               "ProgramArguments" (vector "/bin/launchctl" "list") "StandardOutPath" "/list")
    (let ((launchd (bsd:fork (lambda ()
                               (bsd:chroot (uiop:native-namestring root))
                               (dotimes (i 3)
                                 (bsd:open "/launchd.log" (logior bsd:+o-wronly+ bsd:+o-creat+ bsd:+o-append+)))
                               (bsd:execve "/sbin/launchd" (list "/sbin/launchd") nil)))))
      (unwind-protect
           (progn
             (is (equal (format nil "hcnif~%NIL 1102~%NIL 1100~%")
                        (wait-for-file (merge-pathnames "out" root) (lambda (text) (search "1100" text)))))
             (is (<= 2 (length (wait-for-file (merge-pathnames "again" root) (lambda (text) (<= 2 (length text))) 5))))
             (let ((log (uiop:read-file-string (merge-pathnames "launchd.log" root))))
               (is (search "5 jobs, 1 services, 1 unavailable" log) "~a" log)))
        (bsd:kill launchd :sigkill)
        (bsd:wait4 launchd)))))
