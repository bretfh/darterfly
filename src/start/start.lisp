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

(defparameter *surroundings* '(:network :wifi :battery :errors))

(defun health-path (name) (darterfly/install::esp-path (format nil "~a/health" name)))

(defun recorded-health (name)
  (and name (probe-file (health-path name))
       (with-open-file (s (health-path name))
         (with-standard-io-syntax (let ((*read-eval* nil)) (read s nil))))))

(defun unhealthy (now before)
  (remove-duplicates
   (append (loop for part in '(:log :disk)
                 unless (eq (second (assoc part now)) :ok) collect part)
           (loop for (part status) in before
                 when (and (eq status :ok) (not (member part *surroundings*))
                           (not (eq (second (assoc part now)) :ok)))
                   collect part))))

(defun confirm-when-healthy (&key (tries 10) (every 60))
  (let ((name (darterfly/install:current))
        (before (recorded-health (darterfly/install::link "good"))))
    (loop repeat tries
          for now = (darterfly/health:check)
          for bad = (unhealthy now before)
          do (if (null bad)
                 (progn
                   (with-open-file (s (health-path name) :direction :output :if-exists :supersede)
                     (with-standard-io-syntax (let ((*print-readably* nil)) (prin1 now s))))
                   (darterfly/install:confirm)
                   (format *error-output* "~&confirm: ~a is good~%" name)
                   (return name))
                 (progn
                   (format *error-output* "~&confirm: ~a isn't good yet: ~{~(~a~)~^, ~}~%" name bad)
                   (sleep every)))
          finally (format *error-output* "~&confirm: ~a never became good; the next boot goes back to ~a~%"
                          name (darterfly/install::link "good")))))

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

(defun report-boot-failure (condition)
  (ignore-errors
   (format *error-output* "~&boot failed: ~a~%" condition)
   (sb-debug:print-backtrace :stream *error-output* :count 30)
   (finish-output *error-output*)))

(defun boot ()
  (handler-bind ((error #'report-boot-failure))
    (if (darterfly/run:in-world-p)
        (world-boot)
        (system-boot))))

(defun world-boot ()
  (setf sb-ext:*invoke-debugger-hook* 'darterfly/bsd::report-and-unwind)
  (setf sb-sys::*sbcl-homedir-pathname* (sb-impl::%sbcl-homedir-pathname))
  (attempt "files" #'darterfly/storage:mount-system-files)
  (attempt "console" #'darterfly/bsd::console-fds)
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
      (in-thread "confirm" (lambda () (sleep darterfly/install:*stable-after*) (confirm-when-healthy)))
      (in-thread "saved generation" #'darterfly/install:install-saved-generation))
    (in-thread "brightness" (lambda () (darterfly/devices:start-devices) (darterfly/devices:restore-brightness)))
    (in-thread "display start" #'darterfly/display:start-display)
    (in-thread "audio start" #'darterfly/audio:start-audio)
    (when (attempt "pending build" #'darterfly/generation:pending-build)
      (darterfly/generation:resume-build))
    (sb-thread:make-thread
     (lambda ()
       (attempt "network start" #'darterfly/net:start-network)
       (attempt "driver worlds" #'darterfly/drivers:start-driver-worlds)
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
