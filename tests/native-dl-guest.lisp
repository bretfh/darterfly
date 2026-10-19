(in-package #:cl-user)
(defun dl-check (label ok)
  (format t "~&[DL ~a ~a]~%" label (if ok "PASS" "FAIL"))
  (finish-output)
  (unless ok (error "Dynamic loader check ~a failed" label)))
(defun dl-bytes (path)
  (with-open-file (s path :element-type '(unsigned-byte 8))
    (let ((v (make-array (file-length s) :element-type '(unsigned-byte 8))))
      (read-sequence v s) v)))
(defun dl-save (path bytes)
  (with-open-file (s path :direction :output :if-exists :supersede
                         :element-type '(unsigned-byte 8))
    (write-sequence bytes s)))
(defun dl-u64 (bytes at)
  (loop for i below 8 sum (ash (aref bytes (+ at i)) (* 8 i))))
(defun dl-put64 (bytes at value)
  (dotimes (i 8) (setf (aref bytes (+ at i)) (ldb (byte 8 (* 8 i)) value))))
(defun dl-section (bytes type)
  (loop with start = (dl-u64 bytes 40)
        with count = (+ (aref bytes 60) (ash (aref bytes 61) 8))
        for i below count for at = (+ start (* i 64))
        when (= (aref bytes (+ at 4)) type) return at))
(dolist (part '("leaf" "root" "bad" "probe"))
  (assert (darterfly/cc:compile-native-cxx "/usr/bin/clang"
            (format nil "/Users/darterfly/native-dl-~a.cpp" part)
            (format nil "/tmp/~a.o" part) :pic (not (equal part "probe")) :exceptions nil))
  (format t "~&Compiled ~a~%" part) (finish-output))
(assert (darterfly/cc:link-native-cxx "/usr/bin/ld.lld" "/tmp/libleaf.so"
          '("/tmp/leaf.o") :shared t :soname "libleaf.so" :hash-style "gnu"))
(assert (darterfly/cc:link-native-cxx "/usr/bin/ld.lld" "/tmp/libroot.so"
          '("/tmp/root.o" "/tmp/libleaf.so") :shared t :soname "libroot.so"))
(assert (darterfly/cc:link-native-cxx "/usr/bin/ld.lld" "/tmp/libbad.so"
          '("/tmp/bad.o") :shared t :soname "libbad.so"))
(assert (darterfly/cc:compile-c "/usr/src/darterfly/src/libsa/crt0.S"
                               "/tmp/crt0.o" :compat nil))
(dl-check "BUILD"
  (darterfly/cc:link-native-cxx "/usr/bin/ld.lld" "/tmp/dl-probe"
    '("/tmp/crt0.o" "/tmp/probe.o")))
(dl-save "/tmp/truncated.so" (subseq (dl-bytes "/tmp/libroot.so") 0 63))
(ensure-directories-exist "/tmp/missing/libroot.so")
(dl-save "/tmp/missing/libroot.so" (dl-bytes "/tmp/libroot.so"))
(let* ((v (dl-bytes "/tmp/libroot.so"))
       (section (dl-section v 11)) (off (dl-u64 v (+ section 24)))
       (size (dl-u64 v (+ section 32))))
  ;; First defined ordinary dynamic symbol: invalidate its st_value.
  (loop for at from (+ off 24) below (+ off size) by 24
        when (and (plusp (aref v (+ at 6))) (/= 6 (logand 15 (aref v (+ at 4)))))
        do (dl-put64 v (+ at 8) #x700000000000) (return))
  (dl-save "/tmp/bad-symbol.so" v))
(let* ((v (dl-bytes "/tmp/libroot.so"))
       (section (dl-section v 4)) (off (dl-u64 v (+ section 24))))
  ;; Relocation target outside all segments.
  (dl-put64 v off #x700000000000)
  (dl-save "/tmp/bad-relocation.so" v))
(let* ((v (dl-bytes "/tmp/libroot.so"))
       (init (dl-section v 14)) (target (dl-u64 v (+ init 16)))
       (rela (dl-section v 4)) (off (dl-u64 v (+ rela 24)))
       (size (dl-u64 v (+ rela 32))))
  (loop for at from off below (+ off size) by 24
        when (= (dl-u64 v at) target)
        do (dl-put64 v (+ at 16) 0) (return))
  (dl-save "/tmp/bad-constructor.so" v))
(let* ((v (dl-bytes "/tmp/libroot.so"))
       (rela (dl-section v 4)) (off (dl-u64 v (+ rela 24))))
  (setf (aref v (+ off 8)) 18) ; R_X86_64_TPOFF64 / initial-exec TLS
  (dl-save "/tmp/static-tls.so" v))
(let* ((v (dl-bytes "/tmp/libroot.so"))
       (start (dl-u64 v 32)) (count (aref v 56)))
  (loop for i below count for at = (+ start (* i 56))
        when (and (= 1 (aref v at)) (logbitp 0 (aref v (+ at 4))))
        do (setf (aref v (+ at 4)) 7) (return))
  (dl-save "/tmp/wx.so" v))
(let ((p (sb-ext:run-program "/tmp/dl-probe" '("hold") :search nil :wait nil
                             :input :stream :output *standard-output*
                             :error *error-output*)))
  (unwind-protect
       (progn
         (dl-check "OWN-WORLD"
           (loop repeat 500
                 for proc = (darterfly/bsd:pfind (sb-ext:process-pid p))
                 when (and proc (darterfly/bsd::proc-native-world proc)) return t
                 do (sleep 0.01)))
         (write-char (code-char 71) (sb-ext:process-input p))
         (close (sb-ext:process-input p))
         (sb-ext:process-wait p)
         (dl-check "RUN" (eql 0 (sb-ext:process-exit-code p))))
    (when (eq :running (sb-ext:process-status p)) (sb-ext:process-kill p 9))
    (sb-ext:process-close p)))
(dl-check "FINI" (equal "CRL" (uiop:read-file-string "/tmp/dl-finalized")))
(dolist (kind '("text" "relro"))
  (let ((p (sb-ext:run-program "/tmp/dl-probe" (list kind) :search nil :wait t
                               :output *standard-output* :error *error-output*)))
    (unwind-protect
         (dl-check (if (equal kind "text") "TEXT-PROTECTED" "RELRO-PROTECTED")
           (and (eq :signaled (sb-ext:process-status p))
                (eql 11 (sb-ext:process-exit-code p))))
      (sb-ext:process-close p))))
(dl-check "CLEAN" (zerop (hash-table-count darterfly/bsd::*native-processes*)))


;; Nyxt needs SBCL's ordinary foreign-library path in an isolated Lisp world.
(darterfly/install::esp)
(let* ((code
         "(progn
            (sb-alien:load-shared-object \"/tmp/libroot.so\")
            (sb-alien:define-alien-routine (\"root_value\" loaded-value) sb-alien:int)
            (unless (= 19 (loaded-value)) (error \"DSO call failed\"))
            (format t \"~&[DL LISP-FFI PASS]~%\")
            (sb-ext:exit :code 0))")
       (result (darterfly/run:run-world
                 "/Volumes/EFI/EFI/darterfly/gen-1/darterfly.core"
                 (darterfly/run::world-argv code) :cwd "/" :disk t :timeout 120)))
  (format t "~&Lisp world result: ~s~%" result)
  (dl-check "LISP-WORLD" (eql 0 (getf result :exit))))
