(defpackage #:finch/test
  (:use #:cl #:fiveam)
  (:local-nicknames (#:mach #:finch/mach) (#:plist #:finch/plist)
                    (#:server #:finch/server) (#:ca #:finch/ca) (#:image #:finch/image) (#:bsd #:finch/bsd) (#:launchd #:finch/launchd) (#:xpc #:finch/xpc) (#:apfs #:finch/apfs))
  (:export #:run-them #:all))
(in-package #:finch/test)

(def-suite all)

(defun run-them ()
  (let ((results (unwind-protect (run 'all)
                   (uiop:delete-directory-tree (scratch) :validate t :if-does-not-exist :ignore))))
    (explain! results)
    (unless (results-status results)
      (uiop:quit 1))))

(defvar *finch-root* nil)

(defun finch-file (name)
  (if *finch-root*
      (merge-pathnames name *finch-root*)
      (asdf:system-relative-pathname :finch name)))

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
