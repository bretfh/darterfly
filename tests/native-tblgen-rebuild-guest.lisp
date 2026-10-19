(in-package #:cl-user)
(defun rebuild-check (label ok)
  (format t "~&[TBLGEN-REBUILD ~a ~a]~%" label (if ok "PASS" "FAIL"))
  (finish-output)
  (unless ok (error "TableGen rebuild check ~a" label)))
(defun rebuild-run (tool args &key (code 0) (error *error-output*))
  (let ((p (sb-ext:run-program tool args :search nil :wait t
                              :output *standard-output* :error error)))
    (unwind-protect
         (and (eq :exited (sb-ext:process-status p))
              (eql code (sb-ext:process-exit-code p)))
      (sb-ext:process-close p))))
(defun rebuild-response (path args)
  (ensure-directories-exist path)
  (with-open-file (s path :direction :output :if-exists :supersede)
    (dolist (arg args)
      (write-char #\" s)
      (loop for c across arg do
        (when (find c '(#\" #\\)) (write-char #\\ s)) (write-char c s))
      (write-char #\" s) (terpri s)))
  (list (concatenate 'string "@" path)))
(defun rebuild-elf-p (path)
  (and (probe-file path)
       (with-open-file (s path :element-type '(unsigned-byte 8))
         (let ((header (make-array 4 :element-type '(unsigned-byte 8))))
           (and (> (file-length s) 64) (= 4 (read-sequence header s))
                (equalp header #(127 69 76 70)))))))
(defun rebuild-same (a b)
  (equalp (darterfly/run::read-octets a) (darterfly/run::read-octets b)))
(defparameter *rebuild-plan*
  (with-open-file (s "/usr/share/tblgen-rebuild/plan.sexp")
    (let ((*read-eval* nil)) (read s))))
(destructuring-bind (identity jobs groups direct crt) *rebuild-plan*
  (let ((start (get-internal-real-time)) (compiled 0) (resumed 0))
    (loop for (source object commands) in jobs for index from 1 do
      (let ((stamp (concatenate 'string object ".done")))
        (format t "~&[BUILD ~d/~d] ~a~%" index (length jobs) source)
        (finish-output)
        ;; Only completed guest jobs from this exact source/configuration/seed
        ;; plan may resume. The fresh disk contains no target objects.
        (if (and (rebuild-elf-p object) (probe-file stamp)
                 (string= identity (string-trim '(#\Newline) (uiop:read-file-string stamp))))
            (incf resumed)
            (progn
              (ensure-directories-exist object)
              (uiop:delete-file-if-exists stamp)
              (uiop:delete-file-if-exists object)
              (dolist (args commands)
                (unless (rebuild-run "/usr/bin/clang"
                          (rebuild-response "/work/tblgen/compile.rsp" args))
                  (uiop:delete-file-if-exists object)
                  (error "Native compile failed: ~a" source)))
              (assert (rebuild-elf-p object))
              (with-open-file (s stamp :direction :output :if-exists :supersede)
                (write-line identity s))
              (incf compiled)))))
    (format t "~&[BUILD OBJECTS] ~d compiled, ~d resumed, ~d total; ~,1f seconds~%"
            compiled resumed (length jobs)
            (/ (- (get-internal-real-time) start) internal-time-units-per-second))
    (rebuild-check "SOURCE-CLOSURE" (= (+ compiled resumed) 248)))
  (dolist (group groups)
    (destructuring-bind (archive objects) group
      (uiop:delete-file-if-exists archive)
      (format t "~&[ARCHIVE] ~a (~d objects)~%" archive (length objects))
      (finish-output)
      (assert (rebuild-run "/usr/bin/llvm-ar"
                (rebuild-response "/work/tblgen/archive.rsp" (append (list "rcsD" archive) objects))))))
  (rebuild-check "ARCHIVES" (every (lambda (group) (probe-file (first group))) groups))
  (rebuild-check "LINK"
    (darterfly/cc:link-native-cxx "/usr/bin/ld.lld" "/work/tblgen/clang-tblgen"
      (append (list "--gc-sections" crt) direct
              (list "--start-group") (mapcar #'first groups) (list "--end-group")))))
(rebuild-check "VERSION" (rebuild-run "/work/tblgen/clang-tblgen" '("--version")))
(dolist (test '(("DECLARATIONS" "-gen-clang-decl-nodes" "DeclNodes" "DeclNodes")
                ("STATEMENTS" "-gen-clang-stmt-nodes" "StmtNodes" "StmtNodes")
                ("ATTRIBUTES" "-gen-clang-attr-list" "Attr" "AttrList")))
  (destructuring-bind (label action source output) test
    (let ((out (format nil "/work/tblgen/~a.inc" output)))
      (rebuild-check label
        (and (rebuild-run "/work/tblgen/clang-tblgen"
               (list action "-I" "/usr/src/llvm-project/clang/include"
                     "-I" "/usr/src/llvm-project/llvm/include"
                     (format nil "/usr/src/llvm-project/clang/include/clang/Basic/~a.td" source)
                     "-o" out))
             (rebuild-same out (format nil "/usr/share/tblgen-rebuild/~a.inc" output)))))))
(with-open-file (s "/work/tblgen/edited.td" :direction :output :if-exists :supersede)
  (write-line "include \"clang/Basic/DeclNodes.td\"" s)
  (write-line "def DarterflyWorld : DeclNode<Decl>;" s))
(rebuild-check "EDIT-GENERATE"
  (rebuild-run "/work/tblgen/clang-tblgen"
    '("-gen-clang-decl-nodes" "-I" "/usr/src/llvm-project/clang/include"
      "/work/tblgen/edited.td" "-o" "/work/tblgen/EditedNodes.inc")))
(with-open-file (s "/work/tblgen/client.cpp" :direction :output :if-exists :supersede)
  (write-line "#define DECL(Type, Base) Type," s)
  (write-line "enum class Node {" s)
  (write-line "#include \"EditedNodes.inc\"" s)
  (write-line "};" s)
  (write-line "int main() { static_assert(Node::DarterflyWorld != Node::Function); return 42; }" s))
(rebuild-check "CLIENT-COMPILE"
  (darterfly/cc:compile-native-cxx "/usr/bin/clang" "/work/tblgen/client.cpp" "/work/tblgen/client.o"))
(rebuild-check "CLIENT-LINK"
  (darterfly/cc:link-native-cxx "/usr/bin/ld.lld" "/work/tblgen/client"
    '("/work/tblgen/objects/runtime/crt0.o" "/work/tblgen/client.o" "/work/tblgen/runtime.a")))
(rebuild-check "CLIENT-RUN" (rebuild-run "/work/tblgen/client" nil :code 42))
(rebuild-check "RUNTIME-COMPILE"
  (and (darterfly/cc:compile-native-cxx "/usr/bin/clang"
         "/usr/src/darterfly/tests/native-cxx-probe.cpp" "/work/tblgen/probe.o")
       (darterfly/cc:compile-native-cxx "/usr/bin/clang"
         "/usr/src/darterfly/tests/native-cxx-other.cpp" "/work/tblgen/other.o")))
(rebuild-check "RUNTIME-LINK"
  (darterfly/cc:link-native-cxx "/usr/bin/ld.lld" "/work/tblgen/runtime-probe"
    '("/work/tblgen/objects/runtime/crt0.o" "/work/tblgen/probe.o"
      "/work/tblgen/other.o" "/work/tblgen/runtime.a")))
(rebuild-check "RUNTIME-RUN"
  (rebuild-run "/work/tblgen/runtime-probe" '("/work/tblgen/destructors") :code 42))
(rebuild-check "RUNTIME-DESTRUCTION"
  (string= "TAGZ" (uiop:read-file-string "/work/tblgen/destructors")))
(with-open-file (s "/work/tblgen/broken.td" :direction :output :if-exists :supersede)
  (write-line "def Broken : MissingClass;" s))
(let ((diagnostics (make-string-output-stream)))
  (rebuild-check "DIAGNOSTIC"
    (and (rebuild-run "/work/tblgen/clang-tblgen"
           '("/work/tblgen/broken.td" "-o" "/work/tblgen/broken.inc")
           :code 1 :error diagnostics)
         (search "MissingClass" (get-output-stream-string diagnostics))
         (not (probe-file "/work/tblgen/broken.inc")))))
(rebuild-check "RECOVERY" (rebuild-run "/work/tblgen/clang-tblgen" '("--version")))
(darterfly/vfs:vfs-sync)
(rebuild-check "CLEAN" (zerop (hash-table-count darterfly/bsd::*native-processes*)))
