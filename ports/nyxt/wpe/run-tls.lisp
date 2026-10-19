(require :asdf)
(asdf:load-system :darterfly/test)
(in-package #:darterfly/test)
(let* ((dir (scratch))
       (exe (merge-pathnames "tls-probe" dir))
       (disk (merge-pathnames "tls-probe.img" dir)))
  (darterfly/cc:link-native-program
   exe (mapcar (lambda (p) (namestring (darterfly-file p)))
               '("build/wpe-assessment/tls-guest.o" "build/cxx/crt0.o")))
  (image::root-disk
   disk (* 512 1048576)
   (append (image::root-entries)
           (list (list :file "Users/darterfly/tls-probe"
                       (image::octets exe) #o755))
           (loop for name in '("ca.pem" "untrusted-ca.pem")
                 collect (list :file (concatenate 'string "Users/darterfly/" name)
                   (image::octets
                     (merge-pathnames name (uiop:ensure-directory-pathname
                       (uiop:getenv "DARTER_HTTP_FIXTURE_DIR"))))))))
  (let* ((image::*console-log-directory*
           (merge-pathnames "tls-console/" dir))
         (c (image:bare-console :root disk)))
    (unwind-protect
         (progn
           (image:expect c "* " :timeout 180)
           (image:send c "(progn (darterfly/net:start-network) :network-ready)")
           (image:expect c "* " :timeout 45)
           (image:send c
             "(let* ((path \"/Users/darterfly/tls-probe\")
                     (pid (darterfly/bsd:posix-spawn
                            path (list path) '(\"LANG=C\" \"HOME=/Users/darterfly\")
                            :file-actions
                            `((:open 1 \"/tmp/tls.log\"
                               ,(logior darterfly/bsd:+o-wronly+
                                        darterfly/bsd:+o-creat+
                                        darterfly/bsd:+o-trunc+) 420)
                              (:dup2 1 2)))))
                (unwind-protect
                     (let ((status
                             (loop repeat 12000
                               for result = (multiple-value-list
                                 (darterfly/bsd:wait4 pid :nohang t))
                               when (plusp (first result))
                                 return (second result)
                               do (sleep 0.01))))
                       (with-open-file (s \"/tmp/tls.log\")
                         (loop for line = (read-line s nil)
                               while line do (write-line line)))
                       (format t \"~%[TLS-WORLD STATUS ~s]~%\" status))
                  (ignore-errors (darterfly/bsd:kill pid 9))
                  (ignore-errors (darterfly/bsd:wait4 pid)))
                (format t \"~%[TLS-WORLD SUPERVISOR ~d]~%\" (+ 20 22))
                (format t \"~%[TLS-WORLD DONE]~%\"))")
           (let ((output
                   (image:expect c '("[TLS-WORLD DONE]" "debugger invoked")
                                 :timeout 180)))
             (with-open-file (s (darterfly-file
                                 "build/wpe-assessment/tls-guest.log")
                                :direction :output :if-exists :supersede)
               (write-string output s))
             (write-string output)
             (unless (and (search "[TLS-WORLD STATUS 0]" output)
                          (search "TLS PASS " output)
                          (not (search "WARNING" output))
                          (not (search "CRITICAL" output))
                          (search "[TLS-WORLD SUPERVISOR 42]" output))
               (error "Upstream TLS guest qualification failed"))))
      (image:finish c 5)
      (when (probe-file disk) (delete-file disk)))))
