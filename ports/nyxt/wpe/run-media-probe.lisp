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
           (list (list :file "Users/darterfly/media-probe-checks.lisp"
                       (image::octets (darterfly-file "ports/nyxt/wpe/media-probe-guest.lisp")))
                 (list :file "Users/darterfly/media-probe"
                       (image::octets exe) #o755)
                 (list :file "Users/darterfly/media-h264.mp4"
                       (image::octets (darterfly-file "build/wpe-assessment/media-h264.mp4")))
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
             "(load \"/Users/darterfly/media-probe-checks.lisp\")")
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
                          (search "MEDIA H264 AAC PASS" output)
                          (search "MEDIA MIXED EOS PASS" output)
                          (not (search "CRITICAL" output))
                          (search "[MEDIA-WORLD SUPERVISOR 42]" output))
               (error "Upstream MEDIA guest qualification failed"))))
      (ignore-errors (image:send c "(progn (assert (null darterfly/audio::*pcm-streams*)) (darterfly/audio:audio-status))")
                      (write-string (image:expect c "* " :timeout 10)))
      (ignore-errors (image:qmp "quit"))
      (image:finish c 5)
      (when (probe-file disk) (delete-file disk)))))
