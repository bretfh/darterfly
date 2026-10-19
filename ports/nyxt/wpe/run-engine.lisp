(require :asdf)
(asdf:load-system :darterfly/test)
(in-package #:darterfly/test)
(setf *print-length* 8 *print-level* 5)
(let* ((scratch-root
         (uiop:ensure-directory-pathname
          (string-trim '(#\Space #\Newline #\Return)
           (uiop:read-file-string
             (darterfly-file "build/wpe-assessment/render-build-root.txt")))))
       (dir (merge-pathnames "engine/" scratch-root))
       (exe (merge-pathnames "engine-probe" dir))
       (disk (merge-pathnames "engine-probe.img" dir)))
  (dolist (name '("engine-probe" "WPEWebProcess" "WPENetworkProcess"))
    (format t "~&Linking native ~a~%" name) (finish-output)
    (darterfly/cc:link-native-program
     (merge-pathnames name dir)
     (list (namestring (merge-pathnames (concatenate 'string name "-guest.o") dir))
           (namestring (darterfly-file "build/cxx/runtime.o"))
           (namestring (darterfly-file "build/cxx/crt0.o")))
     :map-file (merge-pathnames (concatenate 'string name ".map") dir)))
  (image::root-disk
   disk (* 1024 1048576)
   (append (image::root-entries)
           (list (list :dir "usr/libexec")
                 (list :dir "usr/libexec/wpe-webkit-2.0")
                 (list :dir "etc/fonts")
                 (list :file "Users/darterfly/engine-probe" (image::octets exe) #o755)
                 (list :file "usr/libexec/wpe-webkit-2.0/WPEWebProcess"
                       (image::octets (merge-pathnames "WPEWebProcess" dir)) #o755)
                 (list :file "usr/libexec/wpe-webkit-2.0/WPENetworkProcess"
                       (image::octets (merge-pathnames "WPENetworkProcess" dir)) #o755)
                 (list :file "Users/darterfly/engine-ca.pem"
                       (concatenate '(vector (unsigned-byte 8))
                         (image::octets "/etc/ssl/certs/ca-certificates.crt")
                         (image::octets
                           (merge-pathnames "ca.pem"
                             (uiop:ensure-directory-pathname
                               (uiop:getenv "DARTER_HTTP_FIXTURE_DIR"))))))
                 (list :file "Users/darterfly/DejaVuSans.ttf"
                       (image::octets
                         "/gnu/store/as4z4fc4za41z0di4dq0kr0sdl48h6nb-font-dejavu-2.37/share/fonts/truetype/DejaVuSans.ttf"))
                 (list :file "etc/fonts/fonts.conf"
                       (image::octets (darterfly-file "ports/nyxt/wpe/engine-fonts.conf"))))))
  (let* ((image::*console-log-directory*
           (merge-pathnames (format nil "engine-console-~d/" (sb-posix:getpid)) dir))
         (c (image:bare-console :root disk :boot-args "init")))
    (unwind-protect
         (progn
           (image:expect c "load_init_program: /sbin/init pid 1" :timeout 180)
           (image:expect c "init: pid 1" :timeout 60)
           (image:send c "(progn (darterfly/net:start-network) :network-ready)")
           (image:expect c "* " :timeout 45)
           (image:send c
             "(let* ((p darterfly/bsd:*proc*)
                     (expected (- (darterfly/vfs:errno-code :eio)))
                     (ok (and
                       (= expected (darterfly/bsd::serve-transfer p 0 :write 1 1 1 0))
                       (= expected (darterfly/bsd::serve-transfer p 0 :pwrite 1 1 1 0))
                       (= expected (darterfly/bsd::serve-socket-transfer p 0 :sendto
                         1 1 1 (make-array 72 :element-type '(unsigned-byte 8)
                                   :initial-element 0) '(0 0 0 0))))))
                (format t \"~%[ENGINE-WORLD DEAD-TRANSFER ~s]~%\" ok))")
           (image:expect c "[ENGINE-WORLD DEAD-TRANSFER T]" :timeout 10)
           (image:expect c "* " :timeout 10)
           (image:send c
             "(let* ((path \"/Users/darterfly/engine-probe\")
                     (pid (darterfly/bsd:posix-spawn
                            path (list path) '(\"LANG=C\" \"HOME=/Users/darterfly\"
                              \"FONTCONFIG_FILE=/etc/fonts/fonts.conf\"
                              \"SSL_CERT_FILE=/Users/darterfly/engine-ca.pem\"
                              \"GIO_USE_TLS=openssl\")
                            :file-actions
                            `((:open 1 \"/tmp/engine.log\"
                               ,(logior darterfly/bsd:+o-wronly+
                                        darterfly/bsd:+o-creat+
                                        darterfly/bsd:+o-trunc+) 420)
                              (:dup2 1 2)))))
                (format t \"~%[ENGINE-WORLD NORMAL-INIT ~s]~%\"
                  (darterfly/bsd::with-bsd
                    (let ((init (darterfly/bsd::pfind 1)))
                      (and (> pid 1) init
                           (eq (darterfly/bsd::proc-state init) :run)
                           (string= (darterfly/bsd::proc-comm init) \"init\")))))
                (unwind-protect
                     (let* ((at 0) (status
                             (loop for attempt below 36000
                               for result = (multiple-value-list
                                 (darterfly/bsd:wait4 pid :nohang t))
                               when (plusp (first result))
                                 return (second result)
                               do (when (zerop (mod attempt 100))
                                    (ignore-errors
                                      (let ((log (uiop:read-file-string \"/tmp/engine.log\")))
                                        (when (> (length log) at)
                                          (write-string log *standard-output* :start at)
                                          (setf at (length log)) (finish-output)))))
                                  (sleep 0.01))))
                       (let ((log (uiop:read-file-string \"/tmp/engine.log\")))
                         (write-string log *standard-output* :start at))
                       (let ((clean
                               (loop repeat 500
                                 when (darterfly/bsd::with-bsd
                                        (zerop (hash-table-count darterfly/bsd::*native-processes*)))
                                   return t
                                 do (sleep 0.01))))
                         (format t \"~%[ENGINE-WORLD CHILDREN-CLEAN ~s]~%\" clean))
                       (let ((reaped
                               (loop repeat 500
                                 when (darterfly/bsd::with-bsd
                                   (not (loop for proc being the hash-values of
                                     darterfly/bsd::*procs*
                                     thereis (member (darterfly/bsd::proc-comm proc)
                                       '(\"engine-probe\" \"WPEWebProcess\" \"WPENetworkProcess\")
                                       :test #'string=))))
                                   return t
                                 do (sleep 0.01))))
                         (format t \"~%[ENGINE-WORLD CHILDREN-REAPED ~s]~%\" reaped))
                       (format t \"~%[ENGINE-WORLD STATUS ~s]~%\" status))
                  (ignore-errors (darterfly/bsd:kill pid 9))
                  (ignore-errors (darterfly/bsd:wait4 pid)))
                (format t \"~%[ENGINE-WORLD SUPERVISOR ~d]~%\" (+ 20 22))
                (format t \"~%[ENGINE-WORLD DONE]~%\"))")
           (let ((output
                   (image:expect c '("[ENGINE-WORLD DONE]" "debugger invoked")
                                 :timeout 420)))
             (with-open-file (s (darterfly-file
                                 "build/wpe-assessment/engine-guest.log")
                                :direction :output :if-exists :supersede)
               (write-string output s))
             (write-string output)
             (unless (and (search "[ENGINE-WORLD STATUS 0]" output)
                          (search "ENGINE PASS COMPLETE" output)
                          (search "[ENGINE-WORLD NORMAL-INIT T]" output)
                          (search "[ENGINE-WORLD CHILDREN-CLEAN T]" output)
                          (search "[ENGINE-WORLD CHILDREN-REAPED T]" output)
                          (not (search "WARNING" output))
                          (not (search "CRITICAL" output))
                          (not (search "Backtrace for:" output))
                          (search "[ENGINE-WORLD SUPERVISOR 42]" output))
               (error "Upstream ENGINE guest qualification failed"))))
      (image:finish c 5)
      (when (probe-file disk) (delete-file disk)))))
