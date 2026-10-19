(in-package #:darterfly/test)
(in-suite guest)
(test native-ipc-on-darterfly
  (let* ((dir (scratch)) (disk (merge-pathnames "native-ipc.img" dir)))
    (image::root-disk disk (* 512 1048576)
      (append (image::root-entries)
        (loop for name in '("native-ipc-probe.c" "native-ipc-guest.lisp")
              collect (list :file (concatenate 'string "Users/darterfly/" name)
                            (image::octets (darterfly-file (concatenate 'string "tests/" name)))))))
    (let* ((image::*console-log-directory* (merge-pathnames "native-ipc-console/" dir))
           (c (image:bare-console :root disk)))
      (unwind-protect
           (progn
             (image:expect c "* " :timeout 180)
             (image:send c "(progn (load \"/Users/darterfly/native-ipc-guest.lisp\") (format t \"~%[NATIVE-IPC DONE]~%\"))")
             (let ((output (image:expect c '("[NATIVE-IPC DONE]" "debugger invoked") :timeout 300)))
               (when (search "debugger invoked" output)
                 (setf output (concatenate 'string output (image:expect c "0] " :timeout 10))))
               (with-open-file (s (merge-pathnames "native-ipc-guest.log" image:*build*)
                                  :direction :output :if-exists :supersede)
                 (write-string output s))
               (dolist (label '("COMPILE" "OWN-WORLD" "STREAM-RIGHTS" "PACKET-RIGHTS"
                                "FLAGS-AND-BOUNDS" "SHM-NAMES" "SHARED-PAGES" "RUN" "CLEAN" "ALIVE"
                                "LISP-WORLD" "OWNER-RELEASED" "ORPHAN-MAPPING" "ORPHAN-WRITE"))
                 (is (search (format nil "[NATIVE-IPC ~a PASS]" label) output)
                     "IPC check ~a: ~a" label output))))
        (image:finish c 5)
        (when (probe-file disk) (delete-file disk))))))
