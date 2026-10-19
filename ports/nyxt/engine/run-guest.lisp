(require :asdf)
(asdf:load-system :darterfly/test)
(in-package #:darterfly/test)
(let* ((dir (scratch))
       (disk (merge-pathnames "cef-boundary.img" dir))
       (runtime (or (uiop:getenv "CEF_PROBE_RUNTIME")
                    (error "Set CEF_PROBE_RUNTIME to the pinned engine directory"))))
  (image::root-disk
   disk (* 1024 1048576)
   (append (image::root-entries)
           (list (list :dir "usr/bin") (list :dir "usr/lib")
                 (list :file "usr/bin/cef-osr-probe"
                       (image::octets (darterfly-file "build/cef-engine/osr-probe")) #o755)
                 (list :file "usr/lib/libcef.so"
                       (image::octets (merge-pathnames "libcef.so"
                                      (uiop:ensure-directory-pathname runtime))) #o755))
           (loop for name in '("guest-probe.c" "guest-probe.lisp")
                 collect (list :file (concatenate 'string "Users/darterfly/" name)
                               (image::octets (darterfly-file
                                 (concatenate 'string "ports/nyxt/engine/" name)))))))
  (let* ((image::*console-log-directory* (merge-pathnames "cef-boundary-console/" dir))
         (c (image:bare-console :root disk)))
    (unwind-protect
         (progn
           (image:expect c "* " :timeout 180)
           (image:send c "(progn (load \"/Users/darterfly/guest-probe.lisp\") (format t \"~%[ENGINE-BOUNDARY DONE]~%\"))")
           (let ((output (image:expect c '("[ENGINE-BOUNDARY DONE]" "debugger invoked")
                                       :timeout 300)))
             (when (search "debugger invoked" output)
               (setf output (concatenate 'string output (image:expect c "0] " :timeout 10))))
             (with-open-file (s (darterfly-file "build/cef-engine/guest.log")
                                :direction :output :if-exists :supersede)
               (write-string output s))
             (dolist (label '("COMPILE" "SOCKET-POLL" "RAM-SHARED-MAPPING" "DISK-SHARED-UNSUPPORTED"
                              "FOREIGN-ENGINE-ABI-REJECTED" "MEMFD-SHIM-UNSUPPORTED"
                              "NATIVE-RUNTIME" "HOST-EXE-REJECTED" "CEF-REJECTED"
                              "CLEAN" "SUPERVISOR-ALIVE"))
               (unless (search (format nil "[ENGINE-BOUNDARY ~a PASS]" label) output)
                 (error "Missing boundary result ~a; see build/cef-engine/guest.log" label)))
             (format t "~&Engine boundary probe: 11/11 observations; engine not running.~%")))
      (image:finish c 5))))
