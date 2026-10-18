(defpackage #:darterfly/start
  (:use #:cl)
  (:export #:boot #:attempt))
(in-package #:darterfly/start)

(defun attempt (name function)
  (block attempt
    (handler-bind ((error (lambda (e)
                            (ignore-errors (darterfly/bsd::note-background-error e))
                            (ignore-errors
                             (format *error-output* "~&~a: ~a~%" name e)
                             (sb-debug:print-backtrace :stream *error-output* :count 15))
                            (return-from attempt nil))))
      (funcall function))))

(defun in-thread (name function)
  (sb-thread:make-thread (lambda () (attempt name function)) :name name))

(defun sources ()
  (or (probe-file "/Users/darterfly/src/darterfly/darterfly.asd")
      (probe-file "/usr/src/darterfly/darterfly.asd")))

(defun register-sources ()
  (uiop:call-image-restore-hook)
  (asdf:clear-output-translations)
  (asdf:clear-source-registry)
  (let ((asd (sources)))
    (when asd
      (asdf:initialize-source-registry
       `(:source-registry (:tree ,(uiop:pathname-directory-pathname asd)) :inherit-configuration))))
  (dolist (system (asdf:already-loaded-systems))
    (unless (uiop:string-prefix-p "darterfly" system)
      (asdf:register-immutable-system system))))

(defun boot ()
  (if (darterfly/run:in-world-p)
      (world-boot)
      (system-boot)))

(defun world-boot ()
  (setf sb-sys::*sbcl-homedir-pathname* (sb-impl::%sbcl-homedir-pathname))
  (register-sources))

(defun system-boot ()
  (darterfly/vfs:vfs-start)
  (darterfly/bsd::libsa-start)
  (darterfly/apfs:mountroot)
  (setf sb-sys::*sbcl-homedir-pathname* (sb-impl::%sbcl-homedir-pathname))
  (register-sources)
  (unless (darterfly/run:in-run-p)
    (attempt "log" #'darterfly/log:start-log)
    (setf darterfly/bsd:*safe* (and (darterfly/devices:boot-arg "safe") t))
    (format *error-output* "~&boot: generation ~a~:[~;, safe~]~%" (ignore-errors (darterfly/install:current)) darterfly/bsd:*safe*)
    (unless darterfly/bsd:*safe*
      (in-thread "confirm" (lambda () (sleep darterfly/install:*stable-after*) (darterfly/install:confirm)))
      (in-thread "saved generation" #'darterfly/install:install-saved-generation))
    (in-thread "brightness" (lambda () (darterfly/devices:start-devices) (darterfly/devices:restore-brightness)))
    (in-thread "display start" #'darterfly/display:start-display)
    (in-thread "audio start" #'darterfly/audio:start-audio)
    (when (attempt "pending build" #'darterfly/generation:pending-build)
      (darterfly/generation:resume-build))
    (sb-thread:make-thread
     (lambda ()
       (attempt "network start" #'darterfly/net:start-network)
       (in-thread "wifi start" #'darterfly/wifi:start-wifi)
       (when (stringp (darterfly/devices:boot-arg "nrepl-key"))
         (attempt "nrepl start" #'darterfly/nrepl:start)))
     :name "network start")
    (when (darterfly/devices:boot-arg "init")
      (sb-thread:make-thread #'darterfly/kernel:launch :name "load_init_program"))
    (sb-thread:make-thread #'darterfly/bsd:resume-activities :name "resume")))

(let ((old (find-symbol "DARTERFLY-BOOT" "COMMON-LISP-USER")))
  (when old
    (setf sb-ext:*init-hooks* (substitute 'boot old sb-ext:*init-hooks*))))
