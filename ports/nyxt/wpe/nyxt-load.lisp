(in-package #:cl-user)
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
               "/usr/lib/nyxt/tls-source-id"))
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
                    (sb-debug:print-backtrace :stream *error-output* :count 45))))))
  (load "/usr/lib/nyxt/nyxt-toolchain.lisp")
  ;; Select is the portable IOLib backend for these services.
  (let ((*features* (remove :linux *features*)))
    (when (probe-file "/Users/darterfly/nyxt-regrovel")
      (asdf:load-system :iolib/syscalls
                        :force '("iolib/syscalls"))
      (delete-file "/Users/darterfly/nyxt-regrovel"))
    (asdf:load-system :iolib)
    (asdf:load-system :iolib/os))
  (asdf:load-system :nyxt))
