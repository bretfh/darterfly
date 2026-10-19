(require :asdf)
;; Load precisely the shared source package that the OS image ships.
(let ((root (merge-pathnames "share/ocicl-source/"
              (uiop:ensure-directory-pathname (uiop:getenv "GUIX_ENVIRONMENT")))))
  (dolist (asd (directory (merge-pathnames "**/*.asd" root)))
    (pushnew (uiop:pathname-directory-pathname asd) asdf:*central-registry*
             :test #'equal)))
(asdf:load-system "pure-tls/cl+ssl-compat")
(asdf:load-system "usocket")
(dolist (port '(18766 18766 18772 18772))
  (let ((socket (usocket:socket-connect "127.0.0.1" port
                                      :element-type '(unsigned-byte 8))))
    (unwind-protect
         (cl+ssl:with-global-context
             ((cl+ssl:make-context :verify-location
                (namestring (merge-pathnames "ca.pem"
                  (uiop:ensure-directory-pathname
                    (uiop:getenv "DARTER_HTTP_FIXTURE_DIR"))))) :auto-free-p t)
           (let ((stream (cl+ssl:make-ssl-client-stream
                           (usocket:socket-stream socket)
                           :hostname "10.0.2.2" :verify t
                           :external-format :utf-8)))
             (unwind-protect
                  (progn
                    (format stream "GET /nyxt HTTP/1.1~c~cHost: 10.0.2.2~c~cConnection: close~c~c~c~c"
                      #\Return #\Newline #\Return #\Newline
                      #\Return #\Newline #\Return #\Newline)
                    (finish-output stream)
                    (assert (search "200 OK" (read-line stream)))
                    (format t "~&[OCICL HOST HTTPS PASS ~d]~%" port))
               (close stream))))
      (usocket:socket-close socket))))
(format t "~&[OCICL HOST REPEATED HTTPS PASS]~%")
