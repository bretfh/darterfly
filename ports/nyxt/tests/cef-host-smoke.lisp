;;;; Host integration probe for the pinned upstream cl-cef backend.
(require :asdf)
(asdf:load-asd (merge-pathnames "cl-cef.asd"
                               (uiop:ensure-directory-pathname
                                (uiop:getenv "CL_CEF_SOURCE"))))
(asdf:load-system :cl-cef)

(defun check (description value)
  (unless value (error "FAIL: ~a" description))
  (format t "~&PASS: ~a~%" description)
  (finish-output))

(let* ((directory (uiop:ensure-directory-pathname
                   (uiop:getenv "CL_CEF_RUNTIME")))
       (cef:*interface*
         (make-instance 'cef:interface
           :library-path (merge-pathnames "libcl-cef.so" directory)
           :subprocess-path (merge-pathnames "cl-cef-helper" directory)
           :resources-dir-path directory
           :locales-dir-path (merge-pathnames "locales/" directory)
           ;; An isolated local fixture; upstream's bridge disables sandboxing.
           :no-sandbox-p t
           :launch-options '("--ozone-platform=x11" "--disable-gpu"
                             "--disable-dev-shm-usage"
                             "--disable-background-networking")))
       (protocol (make-instance 'cef:protocol :scheme-name "darter-test")))
  (cef:handle-callback
   protocol
   (lambda (url)
     (declare (ignore url))
     (values
      "<!doctype html><html><head><title>darter-ready</title>
<style>#probe{width:123px;height:31px;background:rgb(240,120,32)}</style>
</head><body><div id='probe'>Darterfly</div></body></html>"
      "text/html;charset=utf-8" 200)))
  (unwind-protect
       (progn
         (check "engine launched from Lisp" (cef:launch cef:*interface*))
         (let* ((window (make-instance 'cef:window :width 640 :height 480))
                (view (make-instance 'cef:view :url "about:blank"))
                (contents (cef:web-contents view)))
           (cef:add-view window view)
           (cef:load-url view "darter-test://smoke/")
           (check "Lisp custom scheme loaded in renderer"
                  (loop repeat 200
                        when (string= "darter-ready" (cef:get-title contents))
                          return t
                        do (sleep 0.05)))
           (check "JavaScript value returned to Lisp"
                  (eql 42 (cef:execute-javascript-synchronous
                           contents "6 * 7")))
           (check "CSS layout measured through JavaScript"
                  (eql 123 (cef:execute-javascript-synchronous
                            contents
                            "document.getElementById('probe').offsetWidth")))
           (check "DOM text returned to Lisp"
                  (equal "Darterfly"
                         (cef:execute-javascript-synchronous
                          contents
                          "document.getElementById('probe').textContent")))
           (let ((closed (bt:make-semaphore)))
             (cef:add-listener
              view :closed
              (lambda (object data)
                (declare (ignore object data))
                (bt:signal-semaphore closed)
                nil))
             (cef:kill window)
             (check "browser finished asynchronous close"
                    (bt:wait-on-semaphore closed :timeout 10)))))
    (when (cef:alive-p cef:*interface*)
      (cef:terminate cef:*interface*)
      (cef:join cef:*interface*)))
  (check "engine shut down cleanly"
         (and (not (cef:alive-p cef:*interface*))
              (null cef::*launch-error*))))
(format t "~&CEF-HOST-SMOKE-PASS~%")
