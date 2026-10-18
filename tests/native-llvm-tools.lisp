(in-package #:darterfly/test)
(in-suite guest)
(test native-llvm-tools-on-darterfly
  (let* ((dir (scratch)) (disk (merge-pathnames "native-llvm-tools.img" dir))
         (llvm #P"/gnu/store/9s6ip95sbxhfqx63c2nd7lz9xgl701kr-llvm-project-19.1.7-checkout/"))
    (dolist (seed '("build/clang/clang" "build/lld/ld.lld"
                   "build/llvm-tools/llvm-ar" "build/llvm-tools/llvm-tblgen"
                   "build/llvm-tools/clang-tblgen"))
      (unless (probe-file (darterfly-file seed))
        (error "Build the native LLVM tools and compiler/linker seeds first: missing ~a" seed)))
    (image::root-disk
     disk (* 1024 1048576)
     (append
      (image::root-entries)
      (list (list :dir "usr/bin"))
      (image::tree-entries (darterfly-file "build/cxx/include/c++/v1/")
                           "usr/include/c++/v1")
      (image::tree-entries (darterfly-file "build/clang/lib/clang/19/include/")
                           "usr/lib/clang/19/include")
      (list (list :dir "usr/lib/cxx"))
      (loop for tool in '("llvm-ar" "llvm-tblgen" "clang-tblgen" "llvm-ranlib")
            collect (list :file (concatenate 'string "usr/bin/" tool)
                          (image::octets (darterfly-file
                            (concatenate 'string "build/llvm-tools/"
                              (if (string= tool "llvm-ranlib") "llvm-ar" tool)))) #o755))
      (loop for sub in '("llvm/include" "llvm/lib/Target/X86" "clang/include")
            append (image::tree-entries (merge-pathnames (concatenate 'string sub "/") llvm)
                                       (concatenate 'string "usr/src/" sub)))
      (list (list :dir "usr/share/llvm-tools"))
      (loop for (source name) in
            '(("build/clang/include/llvm/IR/Attributes.inc" "Attributes.inc")
              ("build/clang/tools/clang/include/clang/AST/DeclNodes.inc" "DeclNodes.inc")
              ("build/clang/lib/Target/X86/X86GenRegisterInfo.inc" "X86GenRegisterInfo.inc"))
            collect (list :file (concatenate 'string "usr/share/llvm-tools/" name)
                          (image::octets (darterfly-file source))))
      (list (list :file "usr/bin/clang" (image::octets
                          (darterfly-file "build/clang/clang")) #o755)
            (list :file "usr/bin/ld.lld" (image::octets
                          (darterfly-file "build/lld/ld.lld")) #o755)
            (list :file "usr/lib/cxx/runtime.o" (image::octets
                          (darterfly-file "build/cxx/runtime.o")))
            (list :dir "usr/src/darterfly/ports")
            (list :dir "usr/src/darterfly/ports/lld")
            (list :file "usr/src/darterfly/ports/lld/native.ld" (image::octets
                          (darterfly-file "ports/lld/native.ld"))))
      (loop for name in '("native-llvm-tools-guest.lisp" "native-llvm-tools.cpp")
            collect (list :file (concatenate 'string "Users/darterfly/" name)
                          (image::octets (darterfly-file
                                          (concatenate 'string "tests/" name)))))))
    (let* ((image::*console-log-directory* (merge-pathnames "native-llvm-tools-console/" dir))
           (c (image:bare-console :root disk)))
      (unwind-protect
           (progn
             (image:expect c "* " :timeout 180)
             (image:send c "(progn (load \"/Users/darterfly/native-llvm-tools-guest.lisp\") (format t \"~%[LLVM-TOOLS DONE]~%\"))")
             (let ((output (image:expect c '("[LLVM-TOOLS DONE]" "debugger invoked") :timeout 1800)))
               (when (search "debugger invoked" output)
                 (setf output (concatenate 'string output
                                          (image:expect c "0] " :timeout 10))))
               (with-open-file (s (merge-pathnames "native-llvm-tools-guest.log" image:*build*)
                                  :direction :output :if-exists :supersede)
                 (write-string output s))
               (dolist (label '("LLVM-AR" "LLVM-TBLGEN" "CLANG-TBLGEN" "ATTRIBUTES"
                                "DECLARATIONS" "X86-REGISTERS" "EDIT-REGENERATE"
                                "GENERATED-COMPILE" "MEMBER-COMPILE" "UNUSED-COMPILE"
                                "ARCHIVE-CREATE" "ARCHIVE-LIST" "DETERMINISTIC"
                                "ARCHIVE-EXTRACT" "STARTUP"
                                "GENERATE-COMPILE-ARCHIVE-LINK-RUN" "ARCHIVE-REPLACE"
                                "ARCHIVE-DELETE-INDEX" "MISSING-MEMBER"
                                "LLVM-TBLGEN-ERROR" "CLANG-TBLGEN-ERROR" "RECOVERY" "CLEAN"))
                 (is (search (format nil "[LLVM-TOOLS ~a PASS]" label) output)
                     "Native LLVM tools check ~a: ~a" label output))))
        (image:finish c 5)))))
