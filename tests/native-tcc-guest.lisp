(in-package #:cl-user)
(defun tcc-check (label ok)
  (format t "~&[NATIVE-TCC ~a ~a]~%" label (if ok "PASS" "FAIL"))
  (finish-output)
  (unless ok (error "Standalone TCC check ~a failed" label)))
(defun tcc-run (path args)
  (let ((p (sb-ext:run-program path args :search nil :output *standard-output*
                                        :error *error-output*)))
    (unwind-protect (sb-ext:process-exit-code p) (sb-ext:process-close p))))
(defvar *tcc-support*)
(multiple-value-bind (exe support) (darterfly/cc:build-native-tcc "/tmp/tcc-seed" :verbose t)
  (setf *tcc-support* support)
  (tcc-check "SEED" exe))
(tcc-check "VERSION" (= 0 (tcc-run "/tmp/tcc-seed" '("-v"))))
;; Keep TCC blocked on stdin while checking its actual native-world record.
(let ((p (sb-ext:run-program "/tmp/tcc-seed" '("-E" "-") :search nil :wait nil
                             :input :stream :output #P"/tmp/tcc-stdin.log"
                             :error #P"/tmp/tcc-stdin.err")))
  (unwind-protect
       (progn
         (tcc-check "WORLD"
           (loop repeat 500
                 for proc = (darterfly/bsd:pfind (sb-ext:process-pid p))
                 for world = (and proc (darterfly/bsd::proc-native-world proc))
                 when (and world (plusp world)) return t
                 do (sleep 0.01)))
         (write-string (format nil "#define VALUE 173~%int compiler_marker = VALUE;~%")
                       (sb-ext:process-input p))
         (close (sb-ext:process-input p))
         (sb-ext:process-wait p)
         (tcc-check "STDIN"
           (and (eql 0 (sb-ext:process-exit-code p))
                (search "173" (uiop:read-file-string "/tmp/tcc-stdin.log")))))
    (when (eq :running (sb-ext:process-status p)) (sb-ext:process-kill p 9))
    (sb-ext:process-close p)))

(with-open-file (s "/tmp/compiler-bad.c" :direction :output)
  (write-line "#error deliberate compiler diagnostic" s))
(with-open-file (s "/tmp/compiler-bad.o" :direction :output)
  (write-line "stale object must not survive a failed compile" s))
(let ((success t) (code nil))
  (let ((diagnostic
          (with-output-to-string (s)
            (multiple-value-setq (success code)
              (darterfly/cc:compile-native-c "/tmp/tcc-seed" "/tmp/compiler-bad.c"
                                             "/tmp/compiler-bad.o" :error s)))))
    (tcc-check "DIAGNOSTIC"
      (and (not success) (integerp code) (plusp code)
           (search "deliberate compiler diagnostic" diagnostic)
           (not (probe-file "/tmp/compiler-bad.o"))))))
(tcc-check "CWD"
  (and (darterfly/cc:compile-native-c "/tmp/tcc-seed" "native-tcc-probe.c"
                                     "relative.o" :directory "/Users/darterfly/"
                                     :compat nil)
       (probe-file "/Users/darterfly/relative.o")))

(defun tcc-client (compiler prefix)
  (let ((obj (format nil "/tmp/~a.o" prefix))
        (exe (format nil "/tmp/~a" prefix))
        (artifact (format nil "/tmp/~a.txt" prefix)))
    (tcc-check (if (string= prefix "client") "COMPILE" "REBUILT-COMPILE")
               (darterfly/cc:compile-native-c compiler
                 "/Users/darterfly/native-tcc-probe.c" obj :compat nil))
    (darterfly/cc:link-native-program exe (cons obj *tcc-support*))
    (tcc-check (if (string= prefix "client") "RUN" "REBUILT-RUN")
               (and (= 23 (tcc-run exe (list artifact)))
                    (string= (format nil "built by isolated TCC~%")
                             (uiop:read-file-string artifact))))))
(tcc-client "/tmp/tcc-seed" "client")
(multiple-value-bind (exe support)
    (darterfly/cc:build-native-tcc "/tmp/tcc-rebuilt" :compiler "/tmp/tcc-seed"
                                  :work "/tmp/native-tcc-stage2/" :verbose t)
  (setf *tcc-support* support)
  (tcc-check "REBUILD" exe))
(tcc-client "/tmp/tcc-rebuilt" "rebuilt-client")

;; Exercise a further generation, including all compiler support objects.
(tcc-check "THIRD-STAGE"
           (darterfly/cc:build-native-tcc "/tmp/tcc-stage3" :compiler "/tmp/tcc-rebuilt"
                                         :work "/tmp/native-tcc-stage3/" :verbose t))
(tcc-check "STABLE"
           (equalp (darterfly/run::read-octets "/tmp/tcc-rebuilt")
                   (darterfly/run::read-octets "/tmp/tcc-stage3")))
(tcc-check "ALIVE" (= 42 (+ 19 23)))

;; The Lisp build driver also works across the ordinary world boundary.
(darterfly/install::esp)
(let ((code
        (format nil
          "(progn
             (assert (darterfly/cc:compile-native-c
                      \"/tmp/tcc-stage3\" \"/Users/darterfly/native-tcc-probe.c\"
                      \"/tmp/world-client.o\" :compat nil))
             (darterfly/cc:link-native-program \"/tmp/world-client\"
               (cons \"/tmp/world-client.o\" '~s))
             (let ((p (sb-ext:run-program \"/tmp/world-client\"
                         '(\"/tmp/world-client.txt\") :search nil)))
               (unwind-protect (assert (= 23 (sb-ext:process-exit-code p)))
                 (sb-ext:process-close p))))" *tcc-support*)))
  (tcc-check "LISP-WORLD"
    (equal '(:exit 0 :files 0)
           (darterfly/run:run-world
            "/Volumes/EFI/EFI/darterfly/gen-1/darterfly.core"
            (append (darterfly/run::world-argv code) (list "--quit")) :disk t :cwd "/" :timeout 180))))
(tcc-check "LISP-ARTIFACT"
           (string= (format nil "built by isolated TCC~%")
                    (uiop:read-file-string "/tmp/world-client.txt")))
(tcc-check "CLEAN"
           (zerop (hash-table-count darterfly/bsd::*native-processes*)))
