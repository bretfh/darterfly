(defpackage #:darterfly/test
  (:use #:cl #:fiveam)
  (:local-nicknames (#:mach #:darterfly/mach)
                   (#:server #:darterfly/server) (#:layer #:darterfly/layer) (#:image #:darterfly/image) (#:bsd #:darterfly/bsd) (#:init #:darterfly/init) (#:apfs #:darterfly/apfs))
  (:export #:run-them #:all))
(in-package #:darterfly/test)

(def-suite all)

(defun run-them ()
  (let ((results (unwind-protect (run 'all)
                   (uiop:delete-directory-tree (scratch) :validate t :if-does-not-exist :ignore))))
    (explain! results)
    (unless (results-status results)
      (uiop:quit 1))))

(defvar *darterfly-root* nil)

(defun darterfly-file (name)
  (if *darterfly-root*
      (merge-pathnames name *darterfly-root*)
      (asdf:system-relative-pathname :darterfly name)))

(defun scratch ()
  (let ((dir (uiop:ensure-directory-pathname
              (format nil "~a/darterfly-test-~d" (string-right-trim "/" (uiop:native-namestring (uiop:temporary-directory)))
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
