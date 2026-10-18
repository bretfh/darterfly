(in-package #:darterfly/test)
(in-suite guest)
(test native-tblgen-rebuild-on-darterfly
  (let* ((dir (scratch)) (disk (merge-pathnames "tblgen-rebuild.img" image:*build*)))
    (when (image::in-use-p disk)
      (error "Stop the existing rebuild VM before using ~a" disk))
    (unless (uiop:getenv "DARTERFLY_TBLGEN_RESUME")
      (uiop:run-program (list "python3"
                             (namestring (darterfly-file "tools/prepare-tblgen-rebuild.py"))
                             "--verify") :output *standard-output* :error-output *error-output*)
      (image::root-disk disk (* 2048 1048576)
        (append (image::root-entries)
          (image::tree-entries (darterfly-file "build/tblgen-rebuild/root/usr/") "usr")
          (image::tree-entries (darterfly-file "build/cxx/include/c++/v1/") "usr/include/c++/v1")
          (image::tree-entries (darterfly-file "build/clang/lib/clang/19/include/") "usr/lib/clang/19/include")
          (list (list :dir "usr/bin") (list :dir "usr/share/tblgen-rebuild")
                (list :dir "usr/src/darterfly/ports") (list :dir "usr/src/darterfly/ports/lld"))
          (loop for (source target) in
            '(("build/clang/clang" "usr/bin/clang")
              ("build/lld/ld.lld" "usr/bin/ld.lld")
              ("build/llvm-tools/llvm-ar" "usr/bin/llvm-ar"))
            collect (list :file target (image::octets (darterfly-file source)) #o755))
          (loop for (source target) in
            '(("build/tblgen-rebuild/plan.sexp" "usr/share/tblgen-rebuild/plan.sexp")
              ("build/tblgen-rebuild/inputs.json" "usr/share/tblgen-rebuild/inputs.json")
              ("build/clang/tools/clang/include/clang/AST/DeclNodes.inc" "usr/share/tblgen-rebuild/DeclNodes.inc")
              ("build/clang/tools/clang/include/clang/AST/StmtNodes.inc" "usr/share/tblgen-rebuild/StmtNodes.inc")
              ("build/clang/tools/clang/include/clang/Basic/AttrList.inc" "usr/share/tblgen-rebuild/AttrList.inc")
              ("ports/lld/native.ld" "usr/src/darterfly/ports/lld/native.ld")
              ("tests/native-tblgen-rebuild-guest.lisp" "Users/darterfly/native-tblgen-rebuild-guest.lisp"))
            collect (list :file target (image::octets (darterfly-file source)))))))
    (when (uiop:getenv "DARTERFLY_TBLGEN_RESUME")
      (unless (probe-file disk) (error "No saved rebuild disk: ~a" disk))
      ;; Preserve guest-built objects; refresh only the runner, never objects.
      (image::update-root disk
        (list (list :file "Users/darterfly/native-tblgen-rebuild-guest.lisp"
                    (image::octets (darterfly-file "tests/native-tblgen-rebuild-guest.lisp")))
              (list :file "usr/src/darterfly/src/worlds/worlds.lisp"
                    (image::octets (darterfly-file "src/worlds/worlds.lisp"))))))
    (let* ((image::*console-log-directory* (merge-pathnames "native-tblgen-rebuild-console/" dir))
           (c (image:bare-console :root disk)))
      (unwind-protect
           (progn
             (image:expect c "* " :timeout 180)
             (image:send c "(progn (load \"/Users/darterfly/native-tblgen-rebuild-guest.lisp\") (format t \"~%[TBLGEN-REBUILD DONE]~%\"))")
             (let ((output (image:expect c '("[TBLGEN-REBUILD DONE]" "debugger invoked") :timeout 43200)))
               (when (search "debugger invoked" output)
                 (setf output (concatenate 'string output
                                          (image:expect c "0] " :timeout 10))))
               (with-open-file (s (merge-pathnames "native-tblgen-rebuild-guest.log" image:*build*)
                                  :direction :output :if-exists :supersede)
                 (write-string output s))
               (dolist (label '("SOURCE-CLOSURE" "ARCHIVES" "LINK" "VERSION"
                                "DECLARATIONS" "STATEMENTS" "ATTRIBUTES" "EDIT-GENERATE"
                                "CLIENT-COMPILE" "CLIENT-LINK" "CLIENT-RUN"
                                "RUNTIME-COMPILE" "RUNTIME-LINK" "RUNTIME-RUN"
                                "RUNTIME-DESTRUCTION" "DIAGNOSTIC"
                                "RECOVERY" "CLEAN"))
                 (is (and (search "[TBLGEN-REBUILD DONE]" output)
                          (search (format nil "[TBLGEN-REBUILD ~a PASS]" label) output))
                     "Native LLVM tools check ~a: ~a" label output))))
        (image:finish c 5)))))
