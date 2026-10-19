(require :asdf)
(asdf:load-system :darterfly/test)
(in-package #:darterfly/test)
(let* ((dir (scratch))
       (exe (merge-pathnames "render-probe" dir))
       (disk (merge-pathnames "render-probe.img" dir)))
  (darterfly/cc:link-native-program
   exe (mapcar (lambda (p) (namestring (darterfly-file p)))
               '("build/wpe-assessment/render-guest.o" "build/cxx/runtime.o" "build/cxx/crt0.o")))
  (image::root-disk
   disk (* 512 1048576)
   (append (image::root-entries)
           (list (list :file "Users/darterfly/render-probe"
                       (image::octets exe) #o755)
                 (list :file "Users/darterfly/DejaVuSans.ttf"
                       (image::octets (or (uiop:getenv "DARTER_RENDER_FONT")
                         "/gnu/store/as4z4fc4za41z0di4dq0kr0sdl48h6nb-font-dejavu-2.37/share/fonts/truetype/DejaVuSans.ttf"))))))
  (let* ((image::*console-log-directory*
           (merge-pathnames "render-console/" dir))
         (c (image:bare-console :root disk)))
    (unwind-protect
         (progn
           (image:expect c "* " :timeout 180)
           (image:send c
             "(let* ((path \"/Users/darterfly/render-probe\")
                     (pid (darterfly/bsd:posix-spawn
                            path (list path) '(\"LANG=C\" \"HOME=/Users/darterfly\")
                            :file-actions
                            `((:open 1 \"/tmp/render.log\"
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
                       (with-open-file (s \"/tmp/render.log\")
                         (loop for line = (read-line s nil)
                               while line do (write-line line)))
                       (format t \"~%[RENDER-WORLD STATUS ~s]~%\" status))
                  (ignore-errors (darterfly/bsd:kill pid 9))
                  (ignore-errors (darterfly/bsd:wait4 pid)))
                (format t \"~%[RENDER-WORLD SUPERVISOR ~d]~%\" (+ 20 22))
                (format t \"~%[RENDER-WORLD DONE]~%\"))")
           (let ((output
                   (image:expect c '("[RENDER-WORLD DONE]" "debugger invoked")
                                 :timeout 180)))
             (with-open-file (s (darterfly-file
                                 "build/wpe-assessment/render-guest.log")
                                :direction :output :if-exists :supersede)
               (write-string output s))
             (write-string output)
             (unless (and (search "[RENDER-WORLD STATUS 0]" output)
                          (search "RENDER PASS COMPLETE" output)
                          (not (search "WARNING" output))
                          (not (search "CRITICAL" output))
                          (search "[RENDER-WORLD SUPERVISOR 42]" output))
               (error "Upstream RENDER guest qualification failed"))))
      (image:finish c 5)
      (when (probe-file disk) (delete-file disk)))))
