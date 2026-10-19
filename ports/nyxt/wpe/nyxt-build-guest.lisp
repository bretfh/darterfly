(in-package #:cl-user)
(defvar *nyxt-renderer-only* nil)
(let ((failed nil))
  (with-open-file (log "/tmp/nyxt-build.log" :direction :output
                       :if-exists :supersede)
    (let ((*standard-output* log) (*error-output* log) (*trace-output* log)
          (*compile-verbose* t) (*load-verbose* nil)
          (sb-ext:*muffled-warnings* 'sb-ext:compiler-note))
      (handler-case
          (progn
            (format t "~&NYXT native world features: ~s~%" *features*)
            (require :asdf)
            (asdf:initialize-source-registry
             '(:source-registry (:directory "/usr/src/nyxt/")
               (:tree "/usr/src/nyxt/libraries/")
               (:tree "/usr/src/nyxt/_build/") :ignore-inherited-configuration))
            (asdf:initialize-output-translations
             '(:output-translations (t "/Users/darterfly/nyxt-fasl/")
               :ignore-inherited-configuration))
            ;; Reuse OCICL's packaged TLS, without loading its CLI: the CLI
            ;; clears ASDF registrations for its own executable environment.
            (let ((asdf:*central-registry* (copy-list asdf:*central-registry*)))
              (darterfly/apps::register-ocicl-sources)
              ;; Guix sources have fixed timestamps. Invalidate this dependency's
              ;; guest FASLs when its source derivation changes, including patches.
              (let* ((id (uiop:read-file-string
                           "/Users/darterfly/nyxt-tls-source-id"))
                     (stamp "/Users/darterfly/nyxt-tls-built-id")
                     (changed (not (and (probe-file stamp)
                                       (equal id (uiop:read-file-string stamp))))))
                (asdf:load-system "pure-tls/cl+ssl-compat"
                  :force (when changed '("pure-tls" "pure-tls/cl+ssl-compat")))
                (with-open-file (out stamp :direction :output
                                    :if-exists :supersede)
                  (write-string id out)))
              (asdf:register-immutable-system "cl+ssl")
              ;; These dependencies are already resident. Keep their definitions
              ;; with the loaded code instead of redefining packages from another
              ;; vendored version when Nyxt's source registry takes over.
              (dolist (name (sort (copy-list (asdf:already-loaded-systems))
                                 #'string<))
                (let* ((system (asdf:find-system name))
                       (source (asdf:system-source-file system)))
                  (when (and source
                             (uiop:string-prefix-p "/usr/src/ocicl/"
                                                   (namestring source)))
                    (asdf:register-immutable-system name)
                    (format t "~&[NYXT SHARED SYSTEM] ~a ~a ~a~%" name
                            (asdf:component-version system) source)))))
            (assert (and (find-package "PURE-TLS")
                         (fboundp (find-symbol "MAKE-SSL-CLIENT-STREAM" "CL+SSL"))))
            (assert (not (find-package "OCICL")))
            (format t "~&[NYXT OCICL TLS READY]~%")
            (asdf:load-asd "/usr/src/nyxt/libraries/nasdf/nasdf.asd")
            (asdf:load-asd "/usr/src/nyxt/nyxt.asd")
            ;; Upstream explicitly offers this restart for optional spell checking.
            ;; Scope it to the build probe; do not disguise other library failures.
            (handler-bind
                ((error (lambda (condition)
                          (let* ((package (find-package "ENCHANT"))
                                 (name (and package
                                            (find-symbol "SKIP-LOAD-ENCHANT"
                                                         package)))
                                 (restart (and name
                                               (find-restart name condition))))
                            (if restart
                                (progn
                                  (format t "~&[NYXT OPTIONAL ENCHANT UNAVAILABLE] ~a~%"
                                          condition)
                                  (invoke-restart restart))
                                ;; Capture the failing call before HANDLER-CASE
                                ;; unwinds away the dependency's stack frames.
                                (sb-debug:print-backtrace :stream log :count 45))))))
              (load "/Users/darterfly/nyxt-toolchain.lisp")
              ;; Select is the portable IOLib backend for these services.
              (let ((*features* (remove :linux *features*)))
                (when (probe-file "/Users/darterfly/nyxt-regrovel")
                  (asdf:load-system :iolib/syscalls
                                    :force '("iolib/syscalls"))
                  (delete-file "/Users/darterfly/nyxt-regrovel"))
                (asdf:load-system :iolib)
                (asdf:load-system :iolib/os))
              (unless *nyxt-renderer-only*
                (load "/Users/darterfly/nyxt-dependency-checks.lisp"))
              (asdf:load-system :nyxt)
              (format t "~&[NYXT LISP BUILD PASS]~%")
              (finish-output)
              (unless *nyxt-renderer-only*
                (load "/Users/darterfly/nyxt-core-checks.lisp"))
              (when (equal "enabled" (uiop:read-file-string
                                     "/Users/darterfly/nyxt-browser-mode"))
                (sb-posix:setenv "FONTCONFIG_FILE" "/etc/fonts/fonts.conf" 1)
                (sb-posix:setenv "SSL_CERT_FILE" "/Users/darterfly/nyxt-ca.pem" 1)
                (sb-posix:setenv "GIO_USE_TLS" "openssl" 1)
                (load "/Users/darterfly/nyxt-wire.lisp")
                (load "/Users/darterfly/nyxt-renderer.lisp")
                (load "/Users/darterfly/nyxt-browser-checks.lisp")))
            (format t "~&[NYXT QUALIFICATION PASS]~%")
            (finish-output))
        (error (e)
          (when (probe-file "/tmp/nyxt-engine.log")
            (format t "~&[NYXT ENGINE DIAGNOSTIC]~%~a~%"
                    (uiop:read-file-string "/tmp/nyxt-engine.log")))
          (format t "~&[NYXT LISP BUILD ERROR] ~a~%" e)
          (sb-debug:print-backtrace :stream log :count 25)
          (finish-output)
          (setf failed t)))))
  ;; Close the diagnostic file normally before exit; abort-close deletes it.
  (sb-ext:exit :code (if failed 1 0)))
