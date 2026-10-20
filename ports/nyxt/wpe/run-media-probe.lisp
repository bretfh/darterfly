(require :asdf)
(asdf:load-system :darterfly/test)
(in-package #:darterfly/test)
(setf *print-length* 12 *print-level* 5)
(let* ((image:*input-devices* '("virtio-keyboard-pci" "virtio-tablet-pci"
                                       "intel-hda" "hda-duplex,audiodev=media"))
       (image:*extra-qemu* (list "-audiodev" (format nil "wav,id=media,path=~a"
                                      (image::build-path "wpe-assessment/media-output.wav"))))
       (dir (scratch))
       (exe (merge-pathnames "media-probe" dir))
       (disk (merge-pathnames "media-probe.img" dir)))
  (darterfly/cc:link-native-program
   exe (mapcar (lambda (p) (namestring (darterfly-file p)))
               '("build/wpe-assessment/media-guest.o" "build/cxx/crt0.o" "build/cxx/runtime.o")))
  (image::root-disk
   disk (* 512 1048576)
   (append (image::root-entries)
           (list (list :file "Users/darterfly/media-probe"
                       (image::octets exe) #o755)
                 (list :file "Users/darterfly/media-vp9.webm"
                       (image::octets (darterfly-file "build/wpe-assessment/media-vp9.webm")))
                 (list :file "Users/darterfly/media.webm"
                       (image::octets (darterfly-file "build/wpe-assessment/media.webm"))))))
  (let* ((image::*console-log-directory*
           (merge-pathnames "media-console/" dir))
         (c (image:bare-console :root disk)))
    (unwind-protect
         (progn
           (image:expect c "* " :timeout 180)
           (image:send c "(progn (darterfly/audio:start-audio) :audio-ready)")
           (image:expect c "* " :timeout 45)
           (image:send c
             "(let* ((path \"/Users/darterfly/media-probe\")
                     (pid (darterfly/bsd:posix-spawn
                            path (list path) '(\"LANG=C\" \"HOME=/Users/darterfly\")
                            :file-actions
                            `((:open 1 \"/tmp/media.log\"
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
                       (with-open-file (s \"/tmp/media.log\")
                         (loop for line = (read-line s nil)
                               while line do (write-line line)))
                       (format t \"~%[MEDIA-WORLD STATUS ~s]~%\" status))
                  (ignore-errors (darterfly/bsd:kill pid 9))
                  (ignore-errors (darterfly/bsd:wait4 pid)))
                (assert (null darterfly/audio::*pcm-streams*))
                (sleep 0.5)
                (darterfly/audio:play-tone :hz 1000 :seconds 10 :level .02)
                (let ((vp9 (darterfly/bsd:posix-spawn path (list path \"vp9\")
                             '(\"LANG=C\" \"HOME=/Users/darterfly\")
                             :file-actions
                             `((:open 1 \"/tmp/media-vp9.log\"
                                ,(logior darterfly/bsd:+o-wronly+
                                         darterfly/bsd:+o-creat+
                                         darterfly/bsd:+o-trunc+) 420)
                               (:dup2 1 2)))))
                  (unwind-protect
                       (progn
                         (assert (loop repeat 3000
                                   for (pid status) = (multiple-value-list
                                     (darterfly/bsd:wait4 vp9 :nohang t))
                                   when (plusp pid) return (eql status 0)
                                   do (sleep .01)))
                         (assert (search \"NATIVE MEDIA PASS\"
                                         (uiop:read-file-string \"/tmp/media-vp9.log\")))
                         (assert darterfly/audio::*sources*)
                         (format t \"~%[MEDIA VP9 PASS]~%[MEDIA MIXED EOS PASS]~%\"))
                    (ignore-errors (darterfly/bsd:kill vp9 9))))
                (let ((killed (darterfly/bsd:posix-spawn path (list path)
                               '(\"LANG=C\" \"HOME=/Users/darterfly\")
                               :file-actions
                               `((:open 1 \"/tmp/media-killed.log\"
                                  ,(logior darterfly/bsd:+o-wronly+
                                           darterfly/bsd:+o-creat+
                                           darterfly/bsd:+o-trunc+) 420)
                                 (:dup2 1 2)))))
                  (unwind-protect
                       (progn
                         (assert (loop repeat 300 when darterfly/audio::*pcm-streams*
                                       return t do (sleep .01)))
                         (darterfly/bsd:kill killed 9)
                         (darterfly/bsd:wait4 killed)
                         (assert (null darterfly/audio::*pcm-streams*))
                         (format t \"~%[MEDIA CRASH CLEANUP PASS]~%\"))
                    (ignore-errors (darterfly/bsd:kill killed 9))))
                (format t \"~%[MEDIA-WORLD SUPERVISOR ~d]~%\" (+ 20 22))
                (format t \"~%[MEDIA-WORLD DONE]~%\"))")
           (let ((output
                   (image:expect c '("[MEDIA-WORLD DONE]" "debugger invoked")
                                 :timeout 180)))
             (with-open-file (s (darterfly-file
                                 "build/wpe-assessment/media-guest.log")
                                :direction :output :if-exists :supersede)
               (write-string output s))
             (write-string output)
             (unless (and (search "[MEDIA-WORLD STATUS 0]" output)
                          (search "NATIVE MEDIA PASS" output)
                          (search "MEDIA CRASH CLEANUP PASS" output)
                          (search "MEDIA VP9 PASS" output)
                          (search "MEDIA MIXED EOS PASS" output)
                          (not (search "CRITICAL" output))
                          (search "[MEDIA-WORLD SUPERVISOR 42]" output))
               (error "Upstream MEDIA guest qualification failed"))))
      (ignore-errors (image:send c "(progn (assert (null darterfly/audio::*pcm-streams*)) (darterfly/audio:audio-status))")
                      (write-string (image:expect c "* " :timeout 10)))
      (ignore-errors (image:qmp "quit"))
      (image:finish c 5)
      (when (probe-file disk) (delete-file disk)))))
