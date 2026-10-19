(in-package #:cl-user)
;; Build the existing standalone TCC in this guest, then use its CLI for
;; CFFI-generated C. LLD links with the same libsa and CRT as all native worlds.
(defparameter *nyxt-tcc-support* nil)
(defparameter *nyxt-renderer-only*
  (and (probe-file "/Users/darterfly/nyxt-quick-mode")
       (equal "enabled" (uiop:read-file-string
                        "/Users/darterfly/nyxt-quick-mode"))))
(if *nyxt-renderer-only*
    (progn
      ;; Renderer-only development loads previously generated CFFI FASLs.
      ;; Do not claim another compiler build or regenerate native probes here.
      (setf *nyxt-tcc-support* '("/usr/lib/nyxt/crt0.o"))
      (assert (probe-file "/usr/bin/tcc"))
      (format t "~&[NYXT DEVELOPMENT TOOLCHAIN REUSE]~%"))
    (multiple-value-bind (exe support)
        (darterfly/cc:build-native-tcc "/usr/bin/tcc" :verbose t)
      (assert exe)
      (setf *nyxt-tcc-support* support)))
(with-open-file (s "/tmp/nyxt-libsa.o" :direction :output :if-exists :supersede
                   :element-type '(unsigned-byte 8))
  (write-sequence (darterfly/libsa:libsa-object) s))
(asdf:load-system :cffi-grovel)
(setf cffi-toolchain:*cc* "/usr/bin/tcc"
      cffi-toolchain:*cc-flags*
        (append (darterfly/cc:arguments "probe.c" :compat nil
                  :tcc-dir "/usr/lib/tcc/"
                  :libsa-dir "/usr/src/darterfly/src/libsa/")
                '("-I/usr/include"))
      cffi-toolchain:*ld* "/usr/bin/ld.lld"
      cffi-toolchain:*ld-exe-flags*
        (append '("-m" "elf_x86_64" "--threads=1" "--no-mmap-output-file"
                  "-static" "--no-dynamic-linker" "--build-id=none"
                  "-z" "noexecstack" "-T" "/usr/lib/nyxt/native.ld"
                  "/tmp/nyxt-libsa.o")
                *nyxt-tcc-support*)
      cffi-toolchain:*ld-dll-flags*
        '("-m" "elf_x86_64" "--threads=1" "--no-mmap-output-file"
          "-shared" "--hash-style=both" "-z" "now" "-z" "relro"))
;; CFFI precreates its temporary output with mode 0600. LLD's in-memory
;; writer preserves that mode; finish native executable linking as the existing
;; Darterfly linker helper does. Errors from the actual linker still propagate.
(defvar *nyxt-cffi-link-executable* #'cffi-toolchain:link-executable)
(setf (fdefinition 'cffi-toolchain:link-executable)
      (lambda (output inputs)
        (funcall *nyxt-cffi-link-executable* output inputs)
        (sb-posix:chmod output #o755)
        output))
(pushnew #p"/usr/lib/" cffi:*foreign-library-directories* :test #'equal)
(unless *nyxt-renderer-only*
(cffi-toolchain:cc-compile #p"/tmp/nyxt-inputs-probe.o"
                          '(#p"/Users/darterfly/nyxt-inputs-probe.c"))
(cffi-toolchain:link-executable #p"/tmp/nyxt-inputs-probe"
                               '(#p"/tmp/nyxt-inputs-probe.o"))
(sb-posix:chmod "/tmp/nyxt-inputs-probe" #o755)
(uiop:run-program '("/tmp/nyxt-inputs-probe")
                  :output *standard-output* :error-output *error-output*)
(assert (equal "0.4.3"
          (string-trim '(#\Newline #\Return)
            (uiop:run-program '("/usr/bin/pkg-config" "--modversion" "libfixposix")
                              :output :string))))
(unless *nyxt-renderer-only*
  (sb-posix:setenv "NYXT_SPAWN_TEST" "INHERITED" 1)
  (unwind-protect
      (progn
        (assert (equal (format nil "INHERITED~%")
          (uiop:run-program '("/tmp/nyxt-inputs-probe" "--check-environment")
                            :output :string)))
        (assert (equal (format nil "EMPTY~%")
          (uiop:run-program '("/tmp/nyxt-inputs-probe" "--check-environment")
                            :environment nil :output :string))))
    (sb-posix:unsetenv "NYXT_SPAWN_TEST"))
  (format t "~&[NYXT SPAWN ENVIRONMENT PASS]~%"))
(format t "~&[NYXT NATIVE TOOLCHAIN READY]~%")
(finish-output)
)
