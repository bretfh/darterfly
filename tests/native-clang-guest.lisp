(in-package #:cl-user)
(defun clang-check (label ok)
  (format t "~&[CLANG ~a ~a]~%" label (if ok "PASS" "FAIL"))
  (finish-output)
  (unless ok (error "Clang check ~a failed" label)))
(defun clang-run (path args &key (code 0))
  (let ((p (sb-ext:run-program path args :search nil :wait t
                              :output *standard-output* :error *error-output*)))
    (unwind-protect
         (and (eq :exited (sb-ext:process-status p))
              (eql code (sb-ext:process-exit-code p)))
      (sb-ext:process-close p))))
(clang-check "VERSION" (clang-run "/usr/bin/clang" '("-cc1" "-version")))
(clang-check "COMPILE"
  (darterfly/cc:compile-native-cxx "/usr/bin/clang"
    "/Users/darterfly/native-clang-probe.cpp" "/tmp/clang-probe.o"))
(clang-check "OBJECT"
  (with-open-file (s "/tmp/clang-probe.o" :element-type '(unsigned-byte 8))
    (let ((magic (make-array 4 :element-type '(unsigned-byte 8))))
      (read-sequence magic s)
      (and (> (file-length s) 1024) (equalp magic #(127 69 76 70))))))
(assert (darterfly/cc:compile-c "/usr/src/darterfly/src/libsa/crt0.S"
                               "/tmp/clang-crt0.o" :compat nil))
(darterfly/cc:link-native-program "/tmp/clang-probe"
  '("/tmp/clang-crt0.o" "/usr/lib/cxx/runtime.o" "/tmp/clang-probe.o"))
(clang-check "RUN" (clang-run "/tmp/clang-probe" nil :code 42))
;; A compile failure must diagnose the source, remove a stale output and leave
;; the parent world usable for another compilation.
(with-open-file (s "/tmp/bad.cpp" :direction :output :if-exists :supersede)
  (write-line "int main() { this is not C++; }" s))
(let ((diagnostics (make-string-output-stream)))
  (clang-check "DIAGNOSTIC"
    (and (not (darterfly/cc:compile-native-cxx "/usr/bin/clang" "/tmp/bad.cpp"
                "/tmp/clang-probe.o" :output diagnostics :error diagnostics))
         (search "error:" (get-output-stream-string diagnostics))
         (not (probe-file "/tmp/clang-probe.o")))))
(clang-check "RECOMPILE"
  (darterfly/cc:compile-native-cxx "/usr/bin/clang" "native-clang-probe.cpp"
      "/tmp/clang-probe.o" :directory "/Users/darterfly/" :defines '("ANSWER=43")))
(darterfly/cc:link-native-program "/tmp/clang-probe-2"
  '("/tmp/clang-crt0.o" "/usr/lib/cxx/runtime.o" "/tmp/clang-probe.o"))
(clang-check "CHANGED-PROGRAM" (clang-run "/tmp/clang-probe-2" nil :code 43))
(clang-check "LLVM-COMPILE"
  (darterfly/cc:compile-native-cxx "/usr/bin/clang"
    "/usr/src/llvm/lib/ItaniumDemangle.cpp" "/tmp/demangle.o"
    :includes '("/usr/src/llvm/include")))
(clang-check "LLVM-DRIVER"
  (darterfly/cc:compile-native-cxx "/usr/bin/clang"
    "/Users/darterfly/native-clang-demangle.cpp" "/tmp/demangle-driver.o"
    :includes '("/usr/src/llvm/include")))
(darterfly/cc:link-native-program "/tmp/demangle"
  '("/tmp/clang-crt0.o" "/usr/lib/cxx/runtime.o"
    "/tmp/demangle.o" "/tmp/demangle-driver.o"))
(clang-check "LLVM-RUN" (clang-run "/tmp/demangle" nil :code 44))
(clang-check "CLEAN" (zerop (hash-table-count darterfly/bsd::*native-processes*)))
