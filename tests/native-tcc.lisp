(in-package #:darterfly/test)
(in-suite guest)

(defun run-native-tcc-guest (recipe labels)
  (let* ((dir (scratch)) (disk (merge-pathnames "native-tcc.img" dir)))
    (image::root-disk
     disk (* 512 1048576)
     (append (image::root-entries)
             (loop for name in (list recipe "native-tcc-probe.c")
                   collect (list :file (concatenate 'string "Users/darterfly/" name)
                                 (image::octets (darterfly-file
                                                 (concatenate 'string "tests/" name)))))))
    (let* ((image::*console-log-directory* (merge-pathnames "native-tcc-console/" dir))
           (c (image:bare-console :root disk)))
      (unwind-protect
           (progn
             (image:expect c "* " :timeout 120)
             (image:send c (format nil "(progn (load ~s) (format t ~s))"
                                   (concatenate 'string "/Users/darterfly/" recipe)
                                   "~%[NATIVE-TCC DONE]~%"))
             (let ((output (image:expect c (list "[NATIVE-TCC DONE]" "debugger invoked")
                                         :timeout 900)))
               (when (search "debugger invoked" output)
                 (setf output (concatenate 'string output
                                          (image:expect c "0] " :timeout 10))))
               (with-open-file (s (merge-pathnames (make-pathname :name (pathname-name recipe) :type "log") image:*build*)
                                  :direction :output :if-exists :supersede)
                 (write-string output s))
               (dolist (label labels)
                 (is (search (format nil "[NATIVE-TCC ~a PASS]" label) output)
                     "standalone compiler check ~a: ~a" label output))))
        (image:finish c 5)))))

(test standalone-tcc-on-darterfly
  (run-native-tcc-guest
   "native-tcc-guest.lisp"
   '("SEED" "VERSION" "COMPILE" "RUN" "REBUILD"
     "REBUILT-COMPILE" "REBUILT-RUN" "WORLD" "STDIN"
     "DIAGNOSTIC" "CWD" "THIRD-STAGE" "STABLE" "ALIVE"
     "LISP-WORLD" "LISP-ARTIFACT" "CLEAN")))

(test standalone-tcc-large-output-on-darterfly
  (run-native-tcc-guest "native-tcc-large-guest.lisp"
                         '("LARGE-COMPILE" "LARGE-RUN" "STDIO-ERROR")))
