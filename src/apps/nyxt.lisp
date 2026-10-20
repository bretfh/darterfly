(in-package #:darterfly/apps)

(bsd:define-program "Nyxt" (argv envp)
  (unless (darterfly/run:in-world-p)
    (error "Launch Nyxt through open-application in its own app world"))
  ;; Keep diagnostics in the installed OS, including initialization failures.
  (with-open-file (log "/tmp/nyxt-application.log" :direction :output
                       :if-exists :append :if-does-not-exist :create)
    (let* ((*standard-output* log) (*error-output* log) (*trace-output* log)
           (*terminal-io* (make-two-way-stream (make-string-input-stream "") log))
           (*query-io* *terminal-io*) (*debug-io* *terminal-io*))
      (format log "~&[NYXT APPLICATION START ~d]~%" (get-universal-time))
      (finish-output log)
      (handler-case
          (progn
            (load "/usr/lib/nyxt/nyxt-application.lisp")
            (uiop:symbol-call :darterfly/nyxt-application :run argv))
        (error (condition)
          (format log "~&[NYXT APPLICATION FAILED] ~a~%" condition)
          (sb-debug:print-backtrace :stream log :count 30)
          (finish-output log)
          1)))))
