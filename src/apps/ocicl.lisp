(in-package #:darterfly/apps)

(defparameter *ocicl-source* "/usr/src/ocicl/")

(defun register-ocicl-sources ()
  "Make the packaged source closure available without loading the OCICL CLI."
  (dolist (asd (directory (concatenate 'string *ocicl-source* "**/*.asd")))
    (pushnew (directory-namestring asd) asdf:*central-registry* :test #'equal)))

(defun load-ocicl ()
  (unless (find-package "OCICL")
    (register-ocicl-sources)
    (pushnew "SB-ACLREPL" *modules* :test #'string=)
    (let ((*standard-output* (make-broadcast-stream)) (*error-output* (make-broadcast-stream)))
      (handler-bind ((warning #'muffle-warning))
        (asdf:load-system :ocicl)))))

(bsd:define-program "ocicl" (argv envp)
  (load-ocicl)
  (let ((sb-ext:*posix-argv* (cons "ocicl" (rest argv)))
        (*default-pathname-defaults* (pathname (format nil "~a/" (string-right-trim "/" (bsd:getcwd)))))
        (*random-state* *random-state*)
        (uiop:*stderr* *error-output*))
    (funcall (find-symbol "MAIN" "OCICL"))))
