(in-package #:darterfly/test)
(in-suite guest)

(test native-world-survives-s3
  ;; Exercise the actual intersection of D2's CPU/device restore and the
  ;; browser branch's isolated native worlds, descriptor service and reaper.
  (let* ((dir (scratch))
         (exe (merge-pathnames "native-bsd-probe" dir))
         (disk (merge-pathnames "native-sleep.img" dir))
         (image:*extra-qemu* '("-global" "ICH9-LPC.disable_s3=0")))
    (build-libsa-executable exe "tests/native-bsd-probe.c" :raw-call t)
    (image::root-disk
     disk (* 512 1048576)
     (append (image::root-entries)
             (list (list :file "Users/darterfly/native-bsd-probe"
                         (image::octets exe) #o755))))
    (let* ((image::*console-log-directory*
             (merge-pathnames "native-sleep-console/" dir))
           (c (image:bare-console :root disk)))
      (labels ((ask (form)
                 (image:send c form)
                 (image:expect c (format nil "~%* ") :timeout 60)))
        (unwind-protect
             (progn
               (image:expect c "* " :timeout 180)
               (is (search "(:READY 8)"
                     (ask "(progn
                       (ensure-directories-exist \"/tmp/native-work/\")
                       (defvar *baseline* (hash-table-count darterfly/bsd::*procs*))
                       (defvar *channel* (multiple-value-list
                                          (darterfly/bsd:socketpair 1 1)))
                       (defvar *child*
                         (darterfly/bsd:posix-spawn
                           \"/Users/darterfly/native-bsd-probe\"
                           '(\"probe\" \"child-check\" \"space in argument\")
                           '(\"CHILD=exact value\")
                           :file-actions
                           (append (loop for fd below 3 collect
                                     (list :dup2 (second *channel*) fd))
                                   '((:closefrom 3)
                                     (:chdir \"/tmp/native-work\")))))
                       (darterfly/bsd:close (second *channel*))
                       (list :ready (length
                         (darterfly/bsd:read (first *channel*) 8))))"))
                   "native child reaches its blocking read before S3")
               (image:send c
                 "(list :slept (darterfly/power:suspend :check t))")
               (is (loop repeat 60
                         thereis (equal "suspended"
                                        (gethash "status"
                                          (image:qmp "query-status")))
                         do (sleep 0.5)))
               (image:qmp "system_wakeup")
               (is (search "(:SLEPT 1)"
                           (image:expect c (format nil "~%* ") :timeout 60)))
               (is (search "(:RAM T)"
                     (ask "(list :ram (null (getf
                       (darterfly/power::changed-memory) :ranges)))"))
                   "renumbered RAM diagnostic remains intact")
               (is (search "(:LIVE 0)"
                     (ask "(list :live
                       (darterfly/bsd:wait4 *child* :nohang t))")))
               (is (search "(:REPLY #(112 105 110 103))"
                     (ask "(progn
                       (darterfly/bsd:write (first *channel*) #(112 105 110 103))
                       (list :reply
                         (darterfly/bsd:read (first *channel*) 4)))"))
                   "existing socket and child resume across S3")
               (is (search "(:EXIT T)"
                     (ask "(multiple-value-bind (pid status)
                       (darterfly/bsd:wait4 *child*)
                       (list :exit (and (= pid *child*)
                                        (= status (ash 29 8)))))")))
               (is (search "(:NEW T)"
                     (ask "(let ((pid (darterfly/bsd:posix-spawn
                       \"/Users/darterfly/native-bsd-probe\"
                       '(\"probe\" \"exit\") nil)))
                       (multiple-value-bind (found status)
                           (darterfly/bsd:wait4 pid)
                         (list :new (and (= pid found)
                                         (= status (ash 17 8))))))")))
               (is (search "(:CLEAN T)"
                     (ask "(progn (darterfly/bsd:close (first *channel*))
                       (list :clean (= *baseline*
                         (hash-table-count darterfly/bsd::*procs*))))"))))
          (image:finish c 5))))))
