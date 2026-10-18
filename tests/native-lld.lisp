(in-package #:darterfly/test)
(in-suite guest)
(test native-lld-on-darterfly
  (let* ((dir (scratch)) (disk (merge-pathnames "native-lld.img" dir)))
    (dolist (seed '("build/clang/clang" "build/lld/ld.lld"))
      (unless (probe-file (darterfly-file seed))
        (error "Build the native Clang and LLD seeds first: missing ~a" seed)))
    (image::root-disk
     disk (* 1024 1048576)
     (append
      (image::root-entries)
      (image::tree-entries (darterfly-file "build/cxx/include/c++/v1/")
                           "usr/include/c++/v1")
      (image::tree-entries (darterfly-file "build/clang/lib/clang/19/include/")
                           "usr/lib/clang/19/include")
      (list (list :dir "usr/lib/cxx") (list :dir "usr/lib/cxx/objects"))
      (loop for name in (uiop:read-file-lines (darterfly-file "build/cxx/objects.list"))
            collect (list :file (concatenate 'string "usr/lib/cxx/objects/" name)
                          (image::octets (darterfly-file
                                          (concatenate 'string "build/cxx/" name)))))
      (list (list :dir "usr/bin")
            (list :file "usr/bin/clang" (image::octets
                          (darterfly-file "build/clang/clang")) #o755)
            (list :file "usr/bin/ld.lld" (image::octets
                          (darterfly-file "build/lld/ld.lld")) #o755)
            (list :file "usr/lib/cxx/runtime.o" (image::octets
                          (darterfly-file "build/cxx/runtime.o")))
            (list :dir "usr/src/darterfly/ports")
            (list :dir "usr/src/darterfly/ports/lld")
            (list :file "usr/src/darterfly/ports/lld/native.ld" (image::octets
                          (darterfly-file "ports/lld/native.ld"))))
      (loop for name in '("native-lld-guest.lisp" "native-cxx-probe.cpp"
                          "native-cxx-other.cpp" "native-cxx-probe.hpp" "native-lld-tls.cpp")
            collect (list :file (concatenate 'string "Users/darterfly/" name)
                          (image::octets (darterfly-file
                                          (concatenate 'string "tests/" name)))))))
    (let* ((image::*console-log-directory* (merge-pathnames "native-lld-console/" dir))
           (c (image:bare-console :root disk)))
      (unwind-protect
           (progn
             (image:expect c "* " :timeout 180)
             (image:send c "(progn (load \"/Users/darterfly/native-lld-guest.lisp\") (format t \"~%[LLD DONE]~%\"))")
             (let ((output (image:expect c '("[LLD DONE]" "debugger invoked") :timeout 900)))
               (when (search "debugger invoked" output)
                 (setf output (concatenate 'string output
                                          (image:expect c "0] " :timeout 10))))
               (with-open-file (s (merge-pathnames "native-lld-guest.log" image:*build*)
                                  :direction :output :if-exists :supersede)
                 (write-string output s))
               (dolist (label '("VERSION" "COMPILE-MAIN" "COMPILE-OTHER" "COMPILE-UNUSED"
                                "ARCHIVE-LINK" "RUN" "DESTRUCTION" "PARTIAL-LINK"
                                "MMAP-FALLBACK" "RUNTIME-LINK" "PARTIAL-FINAL" "PARTIAL-RUN"
                                "TLS-COMPILE" "TLS-LINK" "TLS-RUN"
                                "DIAGNOSTIC" "RECOVERY" "CLEAN"))
                 (is (search (format nil "[LLD ~a PASS]" label) output)
                     "Native LLD check ~a: ~a" label output))))
        (image:finish c 5)))))
