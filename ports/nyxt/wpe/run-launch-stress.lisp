(require :asdf)
(asdf:load-system :darterfly/test)
(load "ports/nyxt/wpe/app-test-support.lisp")
(in-package #:darterfly/test)
(setf *print-length* 16 *print-level* 6)
(let* ((disk (or (uiop:getenv "DARTERFLY_NYXT_APP_DISK")
                 (error "Supply a disposable browser test disk")))
       (image::*include-browser* t)
       (image::*sbcl-runtime-options* (image::desktop-runtime-options))
       (image:*extra-qemu* (append '("-m" "8192")
                                  (image::desktop-audio-args))))
  (assert (image::nyxt-package-root))
  (assert (not (image::in-use-p disk)))
  (image::update-root disk)
  (image::update-root disk
    (list (list :file "usr/lib/nyxt/nyxt-application.lisp"
      (concatenate '(vector (unsigned-byte 8))
        (image::text "(sb-posix:setenv \"DARTER_NYXT_TRACE\" \"1\" 1)")
        (image::octets (merge-pathnames "usr/lib/nyxt/nyxt-application.lisp"
                         (image::nyxt-package-root)))))))
  (let* ((image::*console-log-directory*
           (image::build-path (format nil "wpe-assessment/launch-stress-~d/"
                                      (get-universal-time))))
         (c (image:console :args (image::bare-qemu
              (image::esp :boot-args (image::root-boot-args "init" disk))
              nil (cons :keep disk) nil))))
    (unwind-protect
      (progn
        (image:expect c "init: pid 1" :timeout 180)
        (nyxt-app-ask c "(progn (sleep 8) (defparameter *nyxt-log-at* 0)
          (defvar *nyxt-app* nil)
          (setf darterfly/layer::*connection*
            (make-instance 'darterfly/layer::connection))
          (defun nyxt-eval (world form &key (timeout 30))
            (let ((reply (darterfly/run:world-eval world form :timeout timeout)))
              (format t \"~&[NYXT EVAL] ~a~%\" reply)
              (assert (not (search \"error: \" reply))) reply)))")
        (dotimes (i (parse-integer (or (uiop:getenv "DARTER_LAUNCH_CYCLES") "6")))
          (nyxt-app-ask c "(progn (setf *nyxt-log-at* 0)
            (uiop:delete-file-if-exists \"/tmp/nyxt-application.log\"))")
          (nyxt-app-dock c)
          (nyxt-app-await c "/tmp/nyxt-application.log" "[NYXT APPLICATION READY]" 600)
          (nyxt-app-ask c "(progn
            (setf *nyxt-app* (darterfly/run:find-world \"Nyxt\"))
            (assert *nyxt-app*)
            (assert (null (getf (darterfly/init:inspect-job \"Nyxt\") :exits))))")
          (nyxt-app-until c "(and (nyxt:current-buffer)
            (plusp (nyxt/renderer/wpe::native-frame-count (nyxt:current-buffer)))
            (= 42 (nyxt:ffi-buffer-evaluate-javascript (nyxt:current-buffer) \"6*7\")))")
          (format t "~&[LAUNCH STRESS ~d READY PASS]~%" (1+ i))
          (image:send-keys (string (code-char 17)))
          (nyxt-app-ask c "(progn
            (assert (loop repeat 600
              when (and (null (darterfly/run:find-world \"Nyxt\"))
                        (zerop (hash-table-count darterfly/bsd::*native-processes*)))
              return t do (sleep .1)))
            (assert (eql 0 (getf (car (last
              (getf (darterfly/init:inspect-job \"Nyxt\") :exits))) :exit))))" 90)
          (format t "~&[LAUNCH STRESS ~d CLEAN QUIT PASS]~%" (1+ i)))
        (format t "~&[LAUNCH STRESS QUALIFICATION PASS]~%"))
      (ignore-errors
        (nyxt-app-ask c "(progn
          (dolist (path '(\"/tmp/nyxt-engine.log\" \"/tmp/nyxt-application.log\"))
            (when (probe-file path)
              (let ((s (uiop:read-file-string path)))
                (format t \"~&[LAUNCH LOG ~a]~%\" path)
                (write-string s *standard-output* :start (max 0 (- (length s) 65536))))))
          (finish-output))" 30))
      (image:finish c 5))))
