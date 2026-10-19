(require :asdf)
(asdf:load-system :darterfly/test)
(in-package #:darterfly/test)
(let* ((dir (scratch))
       (exe (merge-pathnames "glib-probe" dir))
       (disk (merge-pathnames "glib-probe.img" dir)))
  (darterfly/cc:link-native-program
   exe (mapcar (lambda (p) (namestring (darterfly-file p)))
               '("build/wpe-assessment/glib-guest.o" "build/cxx/crt0.o")))
  (image::root-disk
   disk (* 512 1048576)
   (append (image::root-entries)
           (list (list :file "Users/darterfly/glib-probe"
                       (image::octets exe) #o755))))
  (let* ((image::*console-log-directory*
           (merge-pathnames "glib-console/" dir))
         (c (image:bare-console :root disk)))
    (unwind-protect
         (progn
           (image:expect c "* " :timeout 180)
           (image:send c
             "(let* ((path \"/Users/darterfly/glib-probe\")
                     (pid (darterfly/bsd:posix-spawn
                            path (list path) '(\"LANG=C\" \"HOME=/Users/darterfly\")
                            :file-actions
                            `((:open 1 \"/tmp/glib.log\"
                               ,(logior darterfly/bsd:+o-wronly+
                                        darterfly/bsd:+o-creat+
                                        darterfly/bsd:+o-trunc+) 420)
                              (:dup2 1 2)))))
                (unwind-protect
                     (let ((status
                             (loop repeat 6000
                               for result = (multiple-value-list
                                 (darterfly/bsd:wait4 pid :nohang t))
                               when (plusp (first result))
                                 return (second result)
                               do (sleep 0.01))))
                       (with-open-file (s \"/tmp/glib.log\")
                         (loop for line = (read-line s nil)
                               while line do (write-line line)))
                       (format t \"~%[GLIB-WORLD STATUS ~s]~%\" status))
                  (ignore-errors (darterfly/bsd:kill pid 9))
                  (ignore-errors (darterfly/bsd:wait4 pid)))
                (format t \"~%[GLIB-WORLD SUPERVISOR ~d]~%\" (+ 20 22))
                (format t \"~%[GLIB-WORLD DONE]~%\"))")
           (let ((output
                   (image:expect c '("[GLIB-WORLD DONE]" "debugger invoked")
                                 :timeout 120)))
             (with-open-file (s (darterfly-file
                                 "build/wpe-assessment/glib-guest.log")
                                :direction :output :if-exists :supersede)
               (write-string output s))
             (write-string output)
             (unless (and (search "[GLIB-WORLD STATUS 0]" output)
                          (search "GLIB PASS " output)
                          (not (search "GLib-WARNING" output))
                          (search "[GLIB-WORLD SUPERVISOR 42]" output))
               (error "Upstream GLib guest qualification failed"))))
      (image:finish c 5)
      (when (probe-file disk) (delete-file disk)))))
