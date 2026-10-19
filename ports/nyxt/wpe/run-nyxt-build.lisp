(require :asdf)
(asdf:load-system :darterfly/test)
(in-package #:darterfly/test)
(let* ((root (uiop:ensure-directory-pathname
              (string-trim '(#\Newline #\Return #\Space)
                (uiop:read-file-string
                  (darterfly-file "build/wpe-assessment/render-build-root.txt")))))
       (dir (merge-pathnames "nyxt-build/" root))
       (browserp (uiop:getenv "DARTERFLY_NYXT_BROWSER"))
       (disk (merge-pathnames (if browserp "nyxt-browser.img" "nyxt.img") dir)))
  (ensure-directories-exist disk)
  (when (and (probe-file disk) (image::in-use-p disk))
    (error "Nyxt build disk is in use: ~a" disk))
  (let ((pkgconf (merge-pathnames "nyxt-native/root/usr/bin/pkg-config" root)))
    (ensure-directories-exist pkgconf)
    (darterfly/cc:link-native-program pkgconf
      (list (namestring (merge-pathnames "nyxt-native/pkgconf.o" root))
            (namestring (darterfly-file "build/cxx/crt0.o")))))
  (when browserp
    (dolist (name '("nyxt-engine" "WPEWebProcess" "WPENetworkProcess"))
      (darterfly/cc:link-native-program
        (merge-pathnames (concatenate 'string "engine/" name) root)
        (list (namestring (merge-pathnames
                (concatenate 'string "engine/" name "-guest.o") root))
              (namestring (darterfly-file "build/cxx/runtime.o"))
              (namestring (darterfly-file "build/cxx/crt0.o"))))))
  (let ((entries (append (image::root-entries)
      (when browserp
        (append
          (list (list :dir "usr/libexec/wpe-webkit-2.0"))
          (loop for (source target) in
            '(("engine/nyxt-engine" "usr/bin/nyxt-wpe-engine")
              ("engine/WPEWebProcess" "usr/libexec/wpe-webkit-2.0/WPEWebProcess")
              ("engine/WPENetworkProcess" "usr/libexec/wpe-webkit-2.0/WPENetworkProcess"))
            collect (list :file target (image::octets (merge-pathnames source root)) #o755))
          (list (list :file "usr/bin/nyxt-window-server"
                       (image::text (format nil "#!darterfly Nyxt Windows~%")) #o755)
                (list :dir "etc/fonts")
                (list :file "etc/fonts/fonts.conf"
                      (image::octets (darterfly-file "ports/nyxt/wpe/engine-fonts.conf")))
                (list :file "Users/darterfly/DejaVuSans.ttf"
                      (image::octets "/gnu/store/as4z4fc4za41z0di4dq0kr0sdl48h6nb-font-dejavu-2.37/share/fonts/truetype/DejaVuSans.ttf")))))
      (list (list :file "Users/darterfly/nyxt-quick-mode"
                  (image::text (if (uiop:getenv "DARTERFLY_NYXT_QUICK") "enabled" "disabled"))))
      (list (list :file "Users/darterfly/nyxt-browser-mode"
                  (image::text (if browserp "enabled" "disabled"))))
      (image::tree-entries (merge-pathnames "nyxt-native/root/usr/" root) "usr")
      (list (list :dir "usr/lib/nyxt")
            (list :file "Users/darterfly/nyxt-tls-source-id"
              (sb-ext:string-to-octets
                (namestring (truename (merge-pathnames "share/ocicl-source/"
                  (uiop:ensure-directory-pathname (uiop:getenv "GUIX_ENVIRONMENT")))))
                :external-format :utf-8))
            (list :file "Users/darterfly/nyxt-http-mode"
                  (sb-ext:string-to-octets
                    (if (uiop:getenv "DARTER_HTTP_FIXTURE_DIR") "enabled" "disabled")
                    :external-format :utf-8)))
      (when (uiop:getenv "DARTER_HTTP_FIXTURE_DIR")
        (list (list :file "Users/darterfly/nyxt-ca.pem"
                    (image::octets (merge-pathnames "ca.pem"
                      (uiop:ensure-directory-pathname
                        (uiop:getenv "DARTER_HTTP_FIXTURE_DIR")))))))
      (when (uiop:getenv "DARTERFLY_NYXT_REGROVEL")
        (list (list :file "Users/darterfly/nyxt-regrovel"
                    (sb-ext:string-to-octets "refresh" :external-format :utf-8))))
      (loop for (source target) in
        '(("ports/nyxt/wpe/nyxt-wire.lisp" "Users/darterfly/nyxt-wire.lisp")
          ("ports/nyxt/wpe/nyxt-window-server.lisp" "Users/darterfly/nyxt-window-server.lisp")
          ("ports/nyxt/wpe/nyxt-renderer.lisp" "Users/darterfly/nyxt-renderer.lisp")
          ("ports/nyxt/wpe/nyxt-browser-checks.lisp" "Users/darterfly/nyxt-browser-checks.lisp")
          ("build/lld/ld.lld" "usr/bin/ld.lld")
          ("build/cxx/crt0.o" "usr/lib/nyxt/crt0.o")
          ("ports/lld/native.ld" "usr/lib/nyxt/native.ld")
          ("ports/nyxt/wpe/nyxt-core-checks.lisp" "Users/darterfly/nyxt-core-checks.lisp")
          ("ports/nyxt/wpe/nyxt-dependency-checks.lisp" "Users/darterfly/nyxt-dependency-checks.lisp")
          ("ports/nyxt/wpe/nyxt-toolchain.lisp" "Users/darterfly/nyxt-toolchain.lisp")
          ("ports/nyxt/wpe/nyxt-inputs-probe.c" "Users/darterfly/nyxt-inputs-probe.c"))
        collect (list :file target (image::octets (darterfly-file source))
                      (if (equal target "usr/bin/ld.lld") #o755 #o644)))
      (image::tree-entries (merge-pathnames "nyxt-source/" root) "usr/src/nyxt")
      (list (list :file "usr/lib/sbcl/nyxt-build.core"
                   (image::octets (image::darterfly-core)))
            (list :file "Users/darterfly/nyxt-build.lisp"
        (image::octets (darterfly-file "ports/nyxt/wpe/nyxt-build-guest.lisp")))))))
    (if (uiop:getenv "DARTERFLY_NYXT_RESUME")
        (progn
          (unless (probe-file disk) (error "No saved Nyxt build disk: ~a" disk))
          (image::update-root disk entries))
        (image::root-disk disk (* 1024 1048576) entries)))
  (let* ((image::*sbcl-runtime-options*
           (when browserp '("--dynamic-space-size" "2048")))
         (image:*extra-qemu* (append (when browserp '("-m" "8192")) image:*extra-qemu*))
         (image::*console-log-directory* (merge-pathnames (format nil "console-~d-~d/"
             (get-universal-time) (sb-posix:getpid)) dir))
         (c (image:bare-console :root disk :boot-args "init")))
    (unwind-protect
         (progn
           (image:expect c "init: pid 1" :timeout 180)
           (when (uiop:getenv "DARTER_HTTP_FIXTURE_DIR")
             (image:send c "(progn (darterfly/net:start-network) :network-ready)")
             (image:expect c ":NETWORK-READY" :timeout 45)
             (image:expect c "* " :timeout 30))
           (when browserp
             (image:send c
               "(progn (load \"/Users/darterfly/nyxt-wire.lisp\")
                 (load \"/Users/darterfly/nyxt-window-server.lisp\")
                 (defparameter *nyxt-window-adapter*
                   (darterfly/bsd:posix-spawn \"/usr/bin/nyxt-window-server\"
                     '(\"nyxt-window-server\") nil))
                 :window-adapter-started)")
             (let ((reply (image:expect c '(":WINDOW-ADAPTER-STARTED" "debugger invoked") :timeout 30)))
               (unless (search ":WINDOW-ADAPTER-STARTED" reply)
                 (error "Window adapter startup failed: ~a" reply)))
             (image:expect c "* " :timeout 30))
           (image:send c
             "(progn (defparameter *nyxt-build*
               (darterfly/run:start-world
                 \"/usr/lib/sbcl/nyxt-build.core\"
                 (darterfly/run::world-argv
                   \"(load \\\"/Users/darterfly/nyxt-build.lisp\\\")\")
                 :cwd \"/usr/src/nyxt/\" :disk t :timeout 600
                 :name \"Nyxt source build\")) :nyxt-build-started)")
           (let ((reply (image:expect c '(":NYXT-BUILD-STARTED" "debugger invoked") :timeout 60)))
             (unless (search ":NYXT-BUILD-STARTED" reply)
               (error "Could not start the Nyxt build world: ~a" reply)))
           (image:expect c "* " :timeout 30)
           (image:send c
             "(let ((at 0))
                (loop repeat 600
                  do (ignore-errors
                    (let ((log (uiop:read-file-string \"/tmp/nyxt-build.log\")))
                      (when (> (length log) at)
                        (write-string log *standard-output* :start at)
                        (setf at (length log)) (finish-output))))
                  until (member (darterfly/worlds:world-state
                            (darterfly/run:world-id *nyxt-build*)) '(:stopped :gone))
                  do (sleep 1))
                (let ((result (darterfly/run:finish-world *nyxt-build*)))
                  (let ((log (uiop:read-file-string \"/tmp/nyxt-build.log\")))
                    (write-string log *standard-output* :start at))
                  (format t \"~%[NYXT WORLD RESULT ~s]~%\" result))
                (format t \"~%[NYXT BUILD DONE]~%\"))")
           (when browserp
             (let ((out (image:expect c '("[NYXT BROWSER INPUT READY]" "[NYXT LISP BUILD ERROR]" "unhandled condition" "debugger invoked") :timeout 600)))
               (unless (search "[NYXT BROWSER INPUT READY]" out)
                 (error "Browser startup failed: ~a" out)))
             (image:pointer 180 258 t) (sleep .2) (image:pointer 180 258 nil)
             (image:send-keys "darter")
             (dolist (step (list
               (list "[NYXT BROWSER PROMPT REQUEST]" (string (code-char 12)))
               (list "[NYXT BROWSER PROMPT READY]" "https://10.0.2.2:18766/browser?navigation=2")
               (list "[NYXT BROWSER NAVIGATE READY]" (string #\Newline))))
               (let ((out (image:expect c (list (first step) "[NYXT LISP BUILD ERROR]"
                                                "unhandled condition" "debugger invoked")
                                        :timeout 120)))
                 (unless (search (first step) out) (error "Browser command failed: ~a" out)))
               (when (member (first step) '("[NYXT BROWSER PROMPT REQUEST]"
                                            "[NYXT BROWSER PROMPT READY]") :test #'equal)
                 (image:screendump)
                 (uiop:copy-file (darterfly-file "build/screen.ppm")
                   (darterfly-file (if (equal (first step) "[NYXT BROWSER PROMPT REQUEST]")
                     "build/wpe-assessment/nyxt-browser-input.ppm"
                     "build/wpe-assessment/nyxt-browser-prompt.ppm"))))
               (image:send-keys (second step)))
             (let ((out (image:expect c '("[NYXT BROWSER SCREENSHOT READY]" "[NYXT LISP BUILD ERROR]" "unhandled condition" "debugger invoked") :timeout 120)))
               (unless (search "[NYXT BROWSER SCREENSHOT READY]" out)
                 (error "Browser input failed: ~a" out)))
             (image:screendump)
             (uiop:copy-file (darterfly-file "build/screen.ppm")
                            (darterfly-file "build/wpe-assessment/nyxt-browser.ppm")))
           (let ((out (image:expect c '("[NYXT BUILD DONE]" "debugger invoked")
                                   :timeout 660)))
             (when browserp
               (image:expect c "* " :timeout 15)
               (image:send c
                 "(progn
                    (let ((status
                      (loop repeat 500
                        for result = (multiple-value-list
                          (darterfly/bsd:wait4 *nyxt-window-adapter* :nohang t))
                        when (plusp (first result)) return (second result)
                        do (sleep .01))))
                      (format t \"~%[NYXT WINDOW ADAPTER WAIT ~s]~%\" status))
                    (let ((clean
                    (loop repeat 500
                      when (darterfly/bsd::with-bsd
                        (and (zerop (hash-table-count darterfly/bsd::*native-processes*))
                          (not (loop for proc being the hash-values of darterfly/bsd::*procs*
                            thereis (member (darterfly/bsd::proc-comm proc)
                              '(\"nyxt-wpe-engine\" \"WPEWebProcess\" \"WPENetworkProcess\"
                                \"nyxt-window-server\" \"Nyxt Windows\") :test #'string=)))))
                        return t do (sleep .01))))
                    (format t \"~%[NYXT BROWSER CHILDREN REAPED ~s]~%\" clean)))")
               (let ((cleanup (image:expect c '("[NYXT BROWSER CHILDREN REAPED T]"
                                                 "[NYXT BROWSER CHILDREN REAPED NIL]"
                                                 "debugger invoked") :timeout 15)))
                 (unless (search "[NYXT BROWSER CHILDREN REAPED T]" cleanup)
                   (error "Browser left child processes: ~a" cleanup)))
               (setf out (image:transcript c))
               (unless (search "[NYXT WINDOW ADAPTER WAIT 0]" out)
                 (error "Window adapter did not exit successfully")))
             (write-string out)
             (with-open-file (s (darterfly-file "build/wpe-assessment/nyxt-build-guest.log")
                                :direction :output :if-exists :supersede)
               (write-string out s))
             (unless (and (search "[NYXT LISP BUILD PASS]" out)
                          (search "[NYXT QUALIFICATION PASS]" out)
                          (search "[NYXT WORLD RESULT (:EXIT 0" out))
               (error "Nyxt source build has not completed; see guest log"))))
      ;; Preserve guest-produced FASLs for an explicit resume. A default run
      ;; still starts from a fresh disk, so qualification is reproducible.
      (image:finish c 5))))
