(defpackage #:darterfly/shell
  (:use #:cl)
  (:local-nicknames (#:bsd #:darterfly/bsd))
  (:export #:run #:spawn #:ps #:ls #:cat #:halt #:pwd #:cd #:kill))
(in-package #:darterfly/shell)

(defun run (program &rest arguments)
  (finish-output *standard-output*)
  (let ((pid (bsd:posix-spawn program (cons program arguments) nil)))
    (multiple-value-bind (reaped status) (bsd:wait4 pid)
      (declare (ignore reaped))
      (if (bsd:wifexited status) (bsd:wexitstatus status) (- (bsd:wtermsig status))))))

(defun spawn (program &rest arguments)
  (finish-output *standard-output*)
  (bsd:posix-spawn program (cons program arguments) nil))

(defun kill (pid &optional (signal :sigterm))
  (bsd:kill pid signal))

(defun ps ()
  (let ((procs (loop :for proc :being :the :hash-values :of darterfly/bsd::*procs*
                     :collect proc)))
    (format t "  PID  PPID STAT COMMAND~%")
    (dolist (proc (sort procs #'< :key #'darterfly/bsd::proc-pid))
      (format t "~5d ~5d ~4a ~a~%" (darterfly/bsd::proc-pid proc)
              (let ((parent (darterfly/bsd::proc-parent proc))) (if parent (darterfly/bsd::proc-pid parent) 0))
              (case (darterfly/bsd::proc-state proc) (:run "R") (:stop "T") (:zombie "Z"))
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

(defpackage #:darterfly/shell-user
  (:use #:cl #:darterfly/shell))

(bsd:define-program "sh" (argv envp)
  (let ((*package* (find-package :darterfly/shell-user))
        (command (second (member "-c" argv :test #'string=))))
    (when command
      (bsd:exit (handler-case (progn (eval (read-from-string command)) 0)
                  (error (e) (format *error-output* "~a~%" e) 1))))
    (loop
      (format t "# ")
      (finish-output)
      (let ((form (handler-case (read *standard-input* nil :eof)
                    (bsd:errno (e) (format t "~a~%" e) :eof)
                    (error (e) (format t "~a~%" e) (clear-input) nil))))
        (when (eq form :eof) (return 0))
        (handler-case (format t "~{~s~%~}" (multiple-value-list (eval form)))
          (error (e) (format t "~a~%" e)))))))
