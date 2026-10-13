(defpackage #:finch/shell
  (:use #:cl)
  (:local-nicknames (#:bsd #:finch/bsd))
  (:export #:run #:ps #:ls #:cat #:halt #:pwd #:cd))
(in-package #:finch/shell)

(defun run (program &rest arguments)
  (finish-output *standard-output*)
  (let ((pid (bsd:posix-spawn program (cons program arguments) nil)))
    (multiple-value-bind (reaped status) (bsd:wait4 pid)
      (declare (ignore reaped))
      (if (bsd:wifexited status) (bsd:wexitstatus status) (- (bsd:wtermsig status))))))

(defun ps ()
  (let ((procs (loop :for proc :being :the :hash-values :of finch/bsd::*procs*
                     :collect proc)))
    (format t "  PID  PPID STAT COMMAND~%")
    (dolist (proc (sort procs #'< :key #'finch/bsd::proc-pid))
      (format t "~5d ~5d ~4a ~a~%" (finch/bsd::proc-pid proc)
              (let ((parent (finch/bsd::proc-parent proc))) (if parent (finch/bsd::proc-pid parent) 0))
              (case (finch/bsd::proc-state proc) (:run "R") (:stop "T") (:zombie "Z"))
              (bsd:proc-comm proc)))
    (values)))

(defun ls (&optional (dir "."))
  (format t "~{~a~%~}" (sort (bsd:readdir dir) #'string<))
  (values))

(defun cat (path)
  (let ((fd (bsd:open path bsd:+o-rdonly+)))
    (unwind-protect
         (loop :for octets := (bsd:read fd 4096)
               :while (plusp (length octets))
               :do (write-string (sb-ext:octets-to-string octets :external-format :utf-8)))
      (bsd:close fd)))
  (values))

(defun pwd () (bsd:getcwd))

(defun cd (dir) (bsd:chdir dir) (bsd:getcwd))

(defun halt ()
  (finish-output)
  (bsd:reboot 0))

(defpackage #:finch/shell-user
  (:use #:cl #:finch/shell))

(bsd:define-program "sh" (argv envp)
  (let ((*package* (find-package :finch/shell-user)))
    (loop
      (format t "# ")
      (finish-output)
      (let ((form (handler-case (read *standard-input* nil :eof)
                    (bsd:errno (e) (format t "~a~%" e) :eof)
                    (error (e) (format t "~a~%" e) (clear-input) nil))))
        (when (eq form :eof) (return 0))
        (handler-case (format t "~{~s~%~}" (multiple-value-list (eval form)))
          (error (e) (format t "~a~%" e)))))))
