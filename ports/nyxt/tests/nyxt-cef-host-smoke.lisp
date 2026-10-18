;;;; Loaded through Nyxt's normal --load configuration interface.
(in-package :nyxt-user)

(defmethod initialize-instance :after ((interface cef:interface) &key)
  (let ((directory (uiop:ensure-directory-pathname
                    (uiop:getenv "CL_CEF_RUNTIME"))))
    (setf (cef:subprocess-path interface)
          (merge-pathnames "cl-cef-helper" directory)
          (cef:resources-dir-path interface) directory
          (cef:locales-dir-path interface)
          (merge-pathnames "locales/" directory)
          (cef:launch-options interface)
          '("--ozone-platform=x11" "--disable-gpu"
            "--disable-dev-shm-usage" "--disable-background-networking"))))

(defun darterfly-browser-probe (browser)
  (declare (ignore browser))
  (bt:make-thread
   (lambda ()
     (handler-case
         (let ((buffer (nyxt:current-buffer)))
           (assert (loop repeat 200
                         when (string= "darter-nyxt-ready"
                                       (cef:get-title (cef:web-contents buffer)))
                           return t
                         do (sleep 0.05)))
           (assert (= 42 (nyxt:ffi-buffer-evaluate-javascript buffer "6 * 7")))
           (assert (= 123 (nyxt:ffi-buffer-evaluate-javascript
                          buffer
                          "document.getElementById('probe').offsetWidth")))
           (format t "~&NYXT-CEF-HOST-PASS~%")
           (finish-output)
           (nyxt:quit))
       (error (condition)
         (format *error-output* "~&NYXT-CEF-HOST-FAIL: ~a~%" condition)
         (finish-output *error-output*)
         (uiop:quit 1))))
   :name "Darterfly browser probe"))

(define-configuration browser
  ((after-startup-hook
    (hooks:add-hook %slot-value%
                    (make-instance 'hooks:handler
                                   :name 'darterfly-browser-probe
                                   :fn #'darterfly-browser-probe)))))
