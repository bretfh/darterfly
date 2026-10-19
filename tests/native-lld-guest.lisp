(in-package #:cl-user)
(defun lld-check (label ok)
  (format t "~&[LLD ~a ~a]~%" label (if ok "PASS" "FAIL"))
  (finish-output)
  (unless ok (error "LLD check ~a failed" label)))
(defun lld-run (path args &optional (code 0))
  (let ((p (sb-ext:run-program path args :search nil :wait t
                              :output *standard-output* :error *error-output*)))
    (unwind-protect
         (and (eq :exited (sb-ext:process-status p))
              (eql code (sb-ext:process-exit-code p)))
      (sb-ext:process-close p))))
;; A standard indexless ar archive. LLD scans members itself. This fixture is
;; not an ar/ranlib port: the members are all compiled inside this guest.
(defun lld-archive (path members)
  (with-open-file (s path :direction :output :if-exists :supersede
                         :element-type '(unsigned-byte 8))
    (labels ((bytes (text) (map nil (lambda (c) (write-byte (char-code c) s)) text)))
      (bytes (format nil "!<arch>~%"))
      (dolist (member members)
        (with-open-file (input member :element-type '(unsigned-byte 8))
          (let ((size (file-length input)))
            (bytes (format nil "~16a~12a~6a~6a~8a~10a`~%"
                           (concatenate 'string (file-namestring member) "/")
                           "0" "0" "0" "100644" (write-to-string size)))
            (let ((buffer (make-array size :element-type '(unsigned-byte 8))))
              (read-sequence buffer input) (write-sequence buffer s))
            (when (oddp size) (write-byte 10 s))))))))
(lld-check "VERSION" (lld-run "/usr/bin/ld.lld" '("--version")))
(lld-check "COMPILE-MAIN"
  (darterfly/cc:compile-native-cxx "/usr/bin/clang"
    "/Users/darterfly/native-cxx-probe.cpp" "/tmp/main.o"))
(lld-check "COMPILE-OTHER"
  (darterfly/cc:compile-native-cxx "/usr/bin/clang"
    "/Users/darterfly/native-cxx-other.cpp" "/tmp/other.o"))
(with-open-file (s "/tmp/unused.cpp" :direction :output :if-exists :supersede)
  (write-line "extern void deliberately_missing(); void unused() { deliberately_missing(); }" s))
(lld-check "COMPILE-UNUSED"
  (darterfly/cc:compile-native-cxx "/usr/bin/clang" "/tmp/unused.cpp" "/tmp/unused.o"))
(lld-archive "/tmp/other.a" '("/tmp/other.o" "/tmp/unused.o"))
(assert (darterfly/cc:compile-c "/usr/src/darterfly/src/libsa/crt0.S"
                               "/tmp/crt0.o" :compat nil))
(lld-check "ARCHIVE-LINK"
  (darterfly/cc:link-native-cxx "/usr/bin/ld.lld" "/tmp/lld-program"
    '("/tmp/crt0.o" "/usr/lib/cxx/runtime.o" "/tmp/main.o" "/tmp/other.a")))
(lld-check "RUN" (lld-run "/tmp/lld-program" '("/tmp/lld-artifact") 42))
(lld-check "DESTRUCTION" (string= "TAGZ" (uiop:read-file-string "/tmp/lld-artifact")))
(lld-check "PARTIAL-LINK"
  (darterfly/cc:link-native-cxx "/usr/bin/ld.lld" "/tmp/combined.o"
    '("/tmp/main.o" "/tmp/other.o") :relocatable t))
;; Exercise unmodified LLD's default mmap path: libsa must reject unsupported
;; shared file mappings so LLVM falls back to explicit writes, not a zero file.
(lld-check "MMAP-FALLBACK"
  (lld-run "/usr/bin/ld.lld"
    '("--threads=1" "-r" "/tmp/combined.o" "-o" "/tmp/fallback.o")))
;; Replace the host runtime partial link: the recorded upstream component
;; objects are still cross compiled, but their COMDAT/relocation link is native.
(lld-check "RUNTIME-LINK"
  (darterfly/cc:link-native-cxx "/usr/bin/ld.lld" "/tmp/runtime.o"
    (mapcar #'namestring (uiop:directory-files "/usr/lib/cxx/objects/"))
    :relocatable t))
(lld-check "PARTIAL-FINAL"
  (darterfly/cc:link-native-cxx "/usr/bin/ld.lld" "/tmp/lld partial"
    '("/tmp/crt0.o" "/tmp/runtime.o" "/tmp/fallback.o")))
(lld-check "PARTIAL-RUN" (lld-run "/tmp/lld partial" '("/tmp/partial-artifact") 42))
(lld-check "TLS-COMPILE"
  (darterfly/cc:compile-native-cxx "/usr/bin/clang"
    "/Users/darterfly/native-lld-tls.cpp" "/tmp/tls.o"))
(lld-check "TLS-LINK"
  (darterfly/cc:link-native-cxx "/usr/bin/ld.lld" "/tmp/lld-tls"
    '("/tmp/crt0.o" "/tmp/runtime.o" "/tmp/tls.o")))
(lld-check "TLS-RUN" (lld-run "/tmp/lld-tls" nil 43))
;; Undefined-symbol errors remove an old output and leave the parent usable.
(let ((diagnostics (make-string-output-stream)))
  (lld-check "DIAGNOSTIC"
    (and (not (darterfly/cc:link-native-cxx "/usr/bin/ld.lld" "/tmp/lld-program"
                '("/tmp/crt0.o" "/usr/lib/cxx/runtime.o" "/tmp/main.o")
                :output diagnostics :error diagnostics))
         (search "undefined symbol" (get-output-stream-string diagnostics))
         (not (probe-file "/tmp/lld-program"))
         (not (probe-file "/tmp/lld-program.libsa.o"))
         (not (probe-file "/tmp/lld-program.rsp")))))
(lld-check "RECOVERY"
  (darterfly/cc:link-native-cxx "/usr/bin/ld.lld" "/tmp/lld-program"
    '("/tmp/crt0.o" "/usr/lib/cxx/runtime.o" "/tmp/main.o" "/tmp/other.a")))
(lld-check "CLEAN" (zerop (hash-table-count darterfly/bsd::*native-processes*)))
