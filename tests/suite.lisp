(defpackage #:finch/test
  (:use #:cl #:fiveam)
  (:local-nicknames (#:mach #:finch/mach) (#:plist #:finch/plist) (#:macho #:finch/macho)
                    (#:dyld #:finch/dyld))
  (:export #:run-them #:all))
(in-package #:finch/test)

(def-suite all)

(defun run-them ()
  (let ((results (run 'all)))
    (explain! results)
    (unless (results-status results)
      (uiop:quit 1))))

(defun scratch ()
  (let ((dir (uiop:ensure-directory-pathname
              (format nil "~a/finch-test-~d" (string-right-trim "/" (uiop:native-namestring (uiop:temporary-directory)))
                      (sb-posix:getpid)))))
    (ensure-directories-exist dir)
    dir))

(defun sh (&rest args)
  (uiop:run-program args :output :string :error-output :output))

(defmacro fails-with (name &body body)
  `(signals mach:kern-return
     (handler-bind ((mach:kern-return
                      (lambda (c) (is (eq ,name (mach:kern-return-name c))))))
       ,@body)))
