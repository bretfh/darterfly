(in-package #:cl-user)
(defun tools-check (label ok)
  (format t "~&[LLVM-TOOLS ~a ~a]~%" label (if ok "PASS" "FAIL"))
  (finish-output)
  (unless ok (error "LLVM tools check ~a failed" label)))
(defun tools-run (path args &key (code 0) directory
                               (output *standard-output*) (error *error-output*))
  (let ((p (sb-ext:run-program path args :search nil :wait t
                              :directory directory :output output :error error)))
    (unwind-protect
         (and (eq :exited (sb-ext:process-status p))
              (eql code (sb-ext:process-exit-code p)))
      (sb-ext:process-close p))))
(defun tools-same (a b)
  (equalp (darterfly/run::read-octets a) (darterfly/run::read-octets b)))
(defun tools-index-p (path)
  ;; GNU archive symbol table is the first member, named "/".
  (with-open-file (s path :element-type '(unsigned-byte 8))
    (let ((header (make-array 24 :element-type '(unsigned-byte 8))))
      (and (= 24 (read-sequence header s))
           (string= (map 'string #'code-char header)
                    (format nil "!<arch>~%/               "))))))
(defun tools-write (path text)
  (with-open-file (s path :direction :output :if-exists :supersede)
    (write-line text s)))
(dolist (name '("llvm-ar" "llvm-tblgen" "clang-tblgen"))
  (tools-check (string-upcase name)
    (tools-run (concatenate 'string "/usr/bin/" name) '("--version"))))
(tools-check "ATTRIBUTES"
  (and (tools-run "/usr/bin/llvm-tblgen"
         '("-gen-attrs" "/usr/src/llvm/include/llvm/IR/Attributes.td"
           "-o" "/tmp/Attributes.inc"))
       (tools-same "/tmp/Attributes.inc" "/usr/share/llvm-tools/Attributes.inc")))
(tools-check "DECLARATIONS"
  (and (tools-run "/usr/bin/clang-tblgen"
         '("-gen-clang-decl-nodes" "-I" "/usr/src/clang/include"
           "/usr/src/clang/include/clang/Basic/DeclNodes.td"
           "-o" "/tmp/DeclNodes.inc"))
       (tools-same "/tmp/DeclNodes.inc" "/usr/share/llvm-tools/DeclNodes.inc")))
(tools-check "X86-REGISTERS"
  (and (tools-run "/usr/bin/llvm-tblgen"
         '("-gen-register-info" "-I" "/usr/src/llvm/include"
           "-I" "/usr/src/llvm/lib/Target/X86"
           "/usr/src/llvm/lib/Target/X86/X86.td" "-o" "/tmp/X86GenRegisterInfo.inc"))
       (tools-same "/tmp/X86GenRegisterInfo.inc"
                   "/usr/share/llvm-tools/X86GenRegisterInfo.inc")))
;; A source edit in this guest must change the generated compiler vocabulary.
(tools-write "/tmp/extended.td"
  "include \"llvm/IR/Attributes.td\"
def DarterflyWorld : EnumAttr<\"darterfly_world\", [FnAttr]>;")
(tools-check "EDIT-REGENERATE"
  (and (tools-run "/usr/bin/llvm-tblgen"
         '("-gen-attrs" "-I" "/usr/src/llvm/include" "/tmp/extended.td"
           "-o" "/tmp/Attributes.inc"))
       (not (tools-same "/tmp/Attributes.inc" "/usr/share/llvm-tools/Attributes.inc"))
       (search "DarterflyWorld" (uiop:read-file-string "/tmp/Attributes.inc"))))
(tools-check "GENERATED-COMPILE"
  (darterfly/cc:compile-native-cxx "/usr/bin/clang"
    "/Users/darterfly/native-llvm-tools.cpp" "/tmp/generated.o"
    :includes '("/tmp")))
(tools-write "/tmp/member.cpp" "int archive_value() { return 7; }")
(tools-check "MEMBER-COMPILE"
  (darterfly/cc:compile-native-cxx "/usr/bin/clang" "/tmp/member.cpp" "/tmp/member.o"))
(tools-write "/tmp/unused.cpp"
  "extern void missing_symbol(); void unused() { missing_symbol(); }")
(tools-check "UNUSED-COMPILE"
  (darterfly/cc:compile-native-cxx "/usr/bin/clang" "/tmp/unused.cpp" "/tmp/unused.o"))
;; Use an upstream response file, including a space in the archive path.
(tools-write "/tmp/archive.rsp" "rcsD \"/tmp/compiler members.a\" /tmp/member.o /tmp/unused.o")
(tools-check "ARCHIVE-CREATE"
  (and (tools-run "/usr/bin/llvm-ar" '("@/tmp/archive.rsp"))
       (tools-index-p "/tmp/compiler members.a")))
(let ((listing (make-string-output-stream)))
  (tools-check "ARCHIVE-LIST"
    (and (tools-run "/usr/bin/llvm-ar" '("t" "/tmp/compiler members.a") :output listing)
         (string= (format nil "member.o~%unused.o~%") (get-output-stream-string listing)))))
(tools-check "DETERMINISTIC"
  (and (tools-run "/usr/bin/llvm-ar"
         '("rcsD" "/tmp/repeat.a" "/tmp/member.o" "/tmp/unused.o"))
       (tools-same "/tmp/compiler members.a" "/tmp/repeat.a")))
(ensure-directories-exist "/tmp/extract/member.o")
(tools-check "ARCHIVE-EXTRACT"
  (and (tools-run "/usr/bin/llvm-ar" '("x" "/tmp/compiler members.a")
                 :directory "/tmp/extract/")
       (tools-same "/tmp/extract/member.o" "/tmp/member.o")
       (tools-same "/tmp/extract/unused.o" "/tmp/unused.o")))
(tools-check "STARTUP"
  (darterfly/cc:compile-c "/usr/src/darterfly/src/libsa/crt0.S" "/tmp/crt0.o" :compat nil))
(defun tools-link-run (expected)
  (and (darterfly/cc:link-native-cxx "/usr/bin/ld.lld" "/tmp/generated-program"
         '("/tmp/crt0.o" "/usr/lib/cxx/runtime.o" "/tmp/generated.o"
           "/tmp/compiler members.a"))
       (tools-run "/tmp/generated-program" nil :code expected)))
(tools-check "GENERATE-COMPILE-ARCHIVE-LINK-RUN" (tools-link-run 42))
;; Replacement must replace, not append another definition with the same name.
(tools-write "/tmp/member.cpp" "int archive_value() { return 8; }")
(tools-check "ARCHIVE-REPLACE"
  (and (darterfly/cc:compile-native-cxx "/usr/bin/clang" "/tmp/member.cpp" "/tmp/member.o")
       (tools-run "/usr/bin/llvm-ar" '("r" "/tmp/compiler members.a" "/tmp/member.o"))
       (tools-link-run 43)))
(tools-check "ARCHIVE-DELETE-INDEX"
  (and (tools-run "/usr/bin/llvm-ar" '("d" "/tmp/compiler members.a" "unused.o"))
       (tools-run "/usr/bin/llvm-ar" '("s" "/tmp/compiler members.a"))
       (tools-index-p "/tmp/compiler members.a")
       (tools-run "/usr/bin/llvm-ar"
         '("rS" "/tmp/compiler members.a" "/tmp/member.o"))
       (not (tools-index-p "/tmp/compiler members.a"))
       (tools-run "/usr/bin/llvm-ranlib" '("/tmp/compiler members.a"))
       (tools-index-p "/tmp/compiler members.a")
       (tools-link-run 43)))
(let ((diagnostics (make-string-output-stream)))
  (tools-check "MISSING-MEMBER"
    (and (tools-run "/usr/bin/llvm-ar"
           '("r" "/tmp/compiler members.a" "/tmp/absent.o") :code 1 :error diagnostics)
         (search "absent.o" (get-output-stream-string diagnostics))
         (tools-link-run 43))))
(tools-write "/tmp/broken.td" "def Broken : MissingClass;")
(dolist (tool '("llvm-tblgen" "clang-tblgen"))
  (let ((diagnostics (make-string-output-stream)))
    (tools-check (concatenate 'string (string-upcase tool) "-ERROR")
      (and (tools-run (concatenate 'string "/usr/bin/" tool)
             '("/tmp/broken.td" "-o" "/tmp/broken.inc") :code 1 :error diagnostics)
           (search "MissingClass" (get-output-stream-string diagnostics))
           (not (probe-file "/tmp/broken.inc"))))))
(tools-check "RECOVERY"
  (and (tools-run "/usr/bin/llvm-tblgen"
         '("-gen-attrs" "/usr/src/llvm/include/llvm/IR/Attributes.td"
           "-o" "/tmp/recovered.inc"))
       (tools-same "/tmp/recovered.inc" "/usr/share/llvm-tools/Attributes.inc")))
(tools-check "CLEAN" (zerop (hash-table-count darterfly/bsd::*native-processes*)))
