(in-package #:darterfly/test)
(in-suite guest)
(test native-dynamic-loading-on-darterfly
  (let* ((dir (scratch)) (disk (merge-pathnames "native-dl.img" dir)))
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
      (loop for name in '("native-dl-guest.lisp" "native-dl-leaf.cpp" "native-dl-root.cpp"
                          "native-dl-bad.cpp" "native-dl-probe.cpp")
            collect (list :file (concatenate 'string "Users/darterfly/" name)
                          (image::octets (darterfly-file
                                          (concatenate 'string "tests/" name)))))))
    (let* ((image::*console-log-directory* (merge-pathnames "native-dl-console/" dir))
           (c (image:bare-console :root disk)))
      (unwind-protect
           (progn
             (image:expect c "* " :timeout 180)
             (image:send c "(progn (load \"/Users/darterfly/native-dl-guest.lisp\") (format t \"~%[DL DONE]~%\"))")
             (let ((output (image:expect c '("[DL DONE]" "debugger invoked") :timeout 900)))
               (when (search "debugger invoked" output)
                 (setf output (concatenate 'string output
                                          (image:expect c "0] " :timeout 10))))
               (with-open-file (s (merge-pathnames "native-dl-guest.log" image:*build*)
                                  :direction :output :if-exists :supersede)
                 (write-string output s))
               (dolist (label '("BUILD" "OWN-WORLD" "RUN" "FINI" "TEXT-PROTECTED"
                                "RELRO-PROTECTED" "LISP-WORLD" "CLEAN" "LOAD" "ROLLBACK"
                                "CONSTRUCTORS" "CONSTRUCTOR-THREAD" "DEPENDENCY-SCOPE" "SHARED-ALLOCATOR"
                                "SHARED-ERRNO" "CALLBACK" "TLS-MAIN" "TLS-OLD-THREAD"
                                "TLS-NEW-THREAD" "REOPEN-GLOBAL" "TRUNCATED"
                                "BAD-SYMBOL" "BAD-RELOCATION" "BAD-CONSTRUCTOR"
                                "STATIC-TLS-REJECTED" "WX-REJECTED" "THREAD-ERRORS" "TLS-DESTRUCTORS" "MISSING-DEPENDENCY"))
                 (is (search (format nil "[DL ~a PASS]" label) output)
                     "Dynamic loader check ~a: ~a" label output))))
        (image:finish c 5)))))
