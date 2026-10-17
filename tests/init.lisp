(in-package #:darterfly/test)

(def-suite init :in all)
(in-suite init)

(bsd:define-program "darterfly-test-echo" (argv envp)
  (let ((port (init:bootstrap-check-in "darterfly.test.echo")))
    (let ((m (mach:mach-msg-receive port :timeout 5000)))
      (mach:mach-msg-send (mach:make-message :remote-port (mach:msgh-remote-port m)
                                             :remote-disposition :move-send-once
                                             :body (reverse (mach:msgh-body m)))))
    0))

(bsd:define-program "darterfly-test-client" (argv envp)
  (let ((port (init:bootstrap-look-up "darterfly.test.echo"))
        (reply (mach:mach-reply-port)))
    (mach:mach-msg-send (mach:make-message :remote-port port :local-port reply :body "darterfly"))
    (format t "~a~%" (mach:msgh-body (mach:mach-msg-receive reply :timeout 5000)))
    (multiple-value-bind (port kr) (init:bootstrap-look-up "darterfly.test.nobody")
      (format t "~a ~a~%" port kr))
    (multiple-value-bind (port kr) (init:bootstrap-check-in "darterfly.test.echo")
      (format t "~a ~a~%" port kr))
    0))

(bsd:define-program "darterfly-test-again" (argv envp)
  (format t "x")
  3)

(defun job-file (path &rest keys)
  (with-open-file (s path :direction :output :if-exists :supersede)
    (with-standard-io-syntax (prin1 keys s))))

(defun wait-for-file (path test &optional (seconds 10))
  (loop :repeat (* seconds 20)
        :for text := (and (probe-file path) (uiop:read-file-string path))
        :when (and text (funcall test text)) :return text
        :do (sleep 0.05)
        :finally (return text)))

(test init-runs-jobs
  (let* ((root (uiop:ensure-directory-pathname
                (sb-posix:mkdtemp (format nil "~a/root.XXXXXX" (string-right-trim "/" (uiop:native-namestring (scratch)))))))
         (daemons (merge-pathnames "Library/Jobs/" root)))
    (ensure-directories-exist daemons)
    (let ((null (merge-pathnames "dev/null" root)))
      (ensure-directories-exist null)
      (with-open-file (s null :direction :output :if-exists :supersede)))
    (loop :for (path program) :in '(("sbin/init" "init") ("bin/service" "service")
                                    ("usr/libexec/echo" "darterfly-test-echo") ("usr/libexec/client" "darterfly-test-client")
                                    ("usr/libexec/again" "darterfly-test-again"))
          :do (let ((file (merge-pathnames path root)))
                (ensure-directories-exist file)
                (with-open-file (s file :direction :output :if-exists :supersede)
                  (format s "#!darterfly ~a~%" program))
                (sb-posix:chmod (uiop:native-namestring file) #o755)))
    (job-file (merge-pathnames "echo.job" daemons) :label "darterfly.test.echo"
              :program "/usr/libexec/echo" :services '("darterfly.test.echo"))
    (job-file (merge-pathnames "client.job" daemons) :label "darterfly.test.client"
              :arguments '("/usr/libexec/client") :run-at-load t :stdout "/out")
    (job-file (merge-pathnames "again.job" daemons) :label "darterfly.test.again"
              :program "/usr/libexec/again" :keep-alive t :throttle 1 :stdout "/again")
    (job-file (merge-pathnames "missing.job" daemons) :label "darterfly.test.missing"
              :program "/usr/libexec/missing" :run-at-load t)
    (job-file (merge-pathnames "list.job" daemons) :label "darterfly.test.list"
              :arguments '("/bin/service" "list") :stdout "/list")
    (let ((init (bsd:fork (lambda ()
                               (bsd:chroot (uiop:native-namestring root))
                               (dotimes (i 3)
                                 (bsd:open "/init.log" (logior bsd:+o-wronly+ bsd:+o-creat+ bsd:+o-append+)))
                               (bsd:execve "/sbin/init" (list "/sbin/init") nil)))))
      (unwind-protect
           (progn
             (is (equal (format nil "ylfretrad~%NIL UNKNOWN-SERVICE~%NIL NOT-PRIVILEGED~%")
                        (wait-for-file (merge-pathnames "out" root) (lambda (text) (search "PRIVILEGED" text)))))
             (is (<= 2 (length (wait-for-file (merge-pathnames "again" root) (lambda (text) (<= 2 (length text))) 5))))
             (let ((log (uiop:read-file-string (merge-pathnames "init.log" root))))
               (is (search "5 jobs, 1 services, 1 unavailable" log) "~a" log)))
        (bsd:kill init :sigkill)
        (bsd:wait4 init)))))
