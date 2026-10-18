(in-package #:darterfly/test)
(in-suite guest)

(test native-executables-on-darterfly
  (let* ((dir (scratch))
         (exe (merge-pathnames "native-probe" dir))
         (disk (merge-pathnames "native.img" dir)))
    (sh "clang" "--target=x86_64-unknown-none-elf" "-fuse-ld=lld"
        "-nostdlib" "-static" "-fno-stack-protector" "-fno-pie"
        "-mno-red-zone" "-O1" "-Wl,-z,separate-code"
        "-o" (namestring exe)
        (namestring (darterfly-file "tests/native-start.S"))
        (namestring (darterfly-file "tests/native-probe.c")))
    (image::root-disk
     disk (* 512 1048576)
     (append (image::root-entries)
             (loop for name in '("native-start.S" "native-probe.c"
                                 "native-guest.lisp")
                   collect (list :file (concatenate 'string "Users/darterfly/" name)
                                 (image::octets
                                  (darterfly-file
                                   (concatenate 'string "tests/" name)))))
             (list (list :file "Users/darterfly/native-probe" (image::octets exe)))))
    (let* ((image::*console-log-directory*
             (merge-pathnames "native-console/" dir))
           (c (image:bare-console :root disk)))
      (unwind-protect
           (progn
             (image:expect c "* " :timeout 120)
             (image:send c "(load \"/Users/darterfly/native-guest.lisp\")")
             (let ((output (image:expect c (list (format nil "~%* ")
                                                   "debugger invoked")
                                         :timeout 240)))
               (with-open-file (s (merge-pathnames "native-guest.log" image:*build*)
                                  :direction :output :if-exists :supersede)
                 (write-string output s))
               (dolist (label '("HOST-ELF" "PORT" "ZERO-EXIT" "ILLEGAL" "FAULT" "TEXT" "STACK"
                                "NOHANG" "TIMEOUT" "KILL" "DOUBLE-WAIT"
                                "BAD-ELF" "REBUILD" "REBUILT-ELF"
                                "STATUS-LIMIT" "REAP-ALL" "RECLAIM" "ALIVE"))
                 (is (search (format nil "[NATIVE ~a PASS]" label) output)
                     "native guest check ~a: ~a" label output))))
        (image:finish c 5)))))
