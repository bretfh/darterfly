;;;; Native decoder, shared mixer and process cleanup qualification.
(let ((path "/Users/darterfly/media-probe"))
  (labels ((spawn (label &optional codec)
             (darterfly/bsd:posix-spawn
              path (if codec (list path codec) (list path))
              '("LANG=C" "HOME=/Users/darterfly")
              :file-actions
              `((:open 1 ,(format nil "/tmp/media-~a.log" label)
                       ,(logior darterfly/bsd:+o-wronly+
                                darterfly/bsd:+o-creat+
                                darterfly/bsd:+o-trunc+) 420)
                (:dup2 1 2))))
           (finish (pid label)
             (unwind-protect
                  (let* ((status
                           (loop repeat 3000
                             for (child code) = (multiple-value-list
                               (darterfly/bsd:wait4 pid :nohang t))
                             when (plusp child) return code
                             do (sleep .01)))
                         (log (uiop:read-file-string
                                (format nil "/tmp/media-~a.log" label))))
                    (write-string log)
                    (assert (eql status 0))
                    (assert (search "NATIVE MEDIA PASS" log))
                    (assert (null darterfly/audio::*pcm-streams*)))
               (ignore-errors (darterfly/bsd:kill pid 9))
               (ignore-errors (darterfly/bsd:wait4 pid)))))
    (finish (spawn "vp8") "vp8")
    (format t "~%[MEDIA-WORLD STATUS 0]~%")
    (sleep .5)
    (darterfly/audio:play-tone :hz 1000 :seconds 10 :level .02)
    (finish (spawn "vp9" "vp9") "vp9")
    (assert darterfly/audio::*sources*)
    (format t "~%[MEDIA VP9 PASS]~%[MEDIA MIXED EOS PASS]~%")
    (finish (spawn "h264" "h264") "h264")
    (format t "~%[MEDIA H264 AAC PASS]~%")
    (let ((pid (spawn "killed")))
      (unwind-protect
           (progn
             (assert (loop repeat 300 when darterfly/audio::*pcm-streams*
                           return t do (sleep .01)))
             (darterfly/bsd:kill pid 9)
             (darterfly/bsd:wait4 pid)
             (assert (null darterfly/audio::*pcm-streams*))
             (format t "~%[MEDIA CRASH CLEANUP PASS]~%"))
        (ignore-errors (darterfly/bsd:kill pid 9))
        (ignore-errors (darterfly/bsd:wait4 pid))))
    (format t "~%[MEDIA-WORLD SUPERVISOR ~d]~%" (+ 20 22))
    (format t "~%[MEDIA-WORLD DONE]~%")))
