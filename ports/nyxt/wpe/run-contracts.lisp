(require :asdf)
(asdf:load-system :darterfly/test)
(in-package #:darterfly/test)
(let* ((dir (scratch))
       (exe (merge-pathnames "wpe-runtime-contracts" dir))
       (disk (merge-pathnames "wpe-runtime-contracts.img" dir)))
  (build-libsa-executable exe "ports/nyxt/wpe/runtime-contracts.c")
  (image::root-disk
   disk (* 512 1048576)
   (append (image::root-entries)
           (list (list :file "Users/darterfly/wpe-runtime-contracts"
                       (image::octets exe) #o755))))
  (let* ((image::*console-log-directory*
           (merge-pathnames "wpe-contracts-console/" dir))
         (c (image:bare-console :root disk)))
    (unwind-protect
         (progn
           (image:expect c "* " :timeout 180)
           (image:send c
             "(progn
                (dolist (mode '(\"stack\" \"spawn\" \"cond\" \"suspend\"
                                \"spawn-inherit\" \"gc-handshake\"
                                \"math\" \"fenv\" \"child-notification\" \"native-signal\"))
                  (let* ((path \"/Users/darterfly/wpe-runtime-contracts\")
                         (pid (darterfly/bsd:posix-spawn
                                path (list path mode) nil)))
                    (unwind-protect
                         (let ((status
                                 (loop repeat 500
                                   for result = (multiple-value-list
                                     (darterfly/bsd:wait4 pid :nohang t))
                                   when (plusp (first result))
                                     return (second result)
                                   do (sleep 0.01))))
                           (format t \"~%[WPE-CONTRACT ~a ~s]~%\" mode status))
                      (ignore-errors (darterfly/bsd:kill pid 9))
                      (ignore-errors (darterfly/bsd:wait4 pid)))))
                (format t \"~%[WPE-CONTRACT SUPERVISOR ~d]~%\" (+ 20 22))
                (format t \"~%[WPE-CONTRACT DONE]~%\"))")
           (let ((output
                   (image:expect c '("[WPE-CONTRACT DONE]"
                                     "debugger invoked") :timeout 90)))
             (with-open-file
                 (s (darterfly-file "build/wpe-assessment/contracts-guest.log")
                    :direction :output :if-exists :supersede)
               (write-string output s))
             (write-string output)
             (unless (search "[WPE-CONTRACT DONE]" output)
               (error "Contract harness did not complete"))
             (dolist (mode '("stack" "spawn" "cond" "suspend"
                             "spawn-inherit" "gc-handshake" "math" "fenv"
                             "child-notification" "native-signal"))
               (unless (search (format nil "[WPE-CONTRACT ~a 0]" mode) output)
                 (error "Contract failed: ~a" mode)))))
      (image:finish c 5)
      (when (probe-file disk) (delete-file disk)))))
