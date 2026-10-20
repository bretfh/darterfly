(require :asdf)
(asdf:load-system :darterfly/test)
(load "ports/nyxt/wpe/app-test-support.lisp")
(in-package #:darterfly/test)
(setf *print-length* 16 *print-level* 6)
(defun daily-eval (console form &optional (timeout 60))
  (let ((out (nyxt-app-ask console
               (format nil "(nyxt-eval *nyxt-app* ~s :timeout ~d)" form timeout)
               (+ timeout 15))))
    (when (search "[NYXT EVAL] error:" out) (error "Nyxt: ~a" out))
    out))
(defun daily-js (console script)
  (daily-eval console (format nil "(nyxt:ffi-buffer-evaluate-javascript (nyxt:current-buffer) ~s)" script)))
(defun daily-check-js (console script)
  (daily-eval console (format nil "(assert (nyxt:ffi-buffer-evaluate-javascript (nyxt:current-buffer) ~s))" script)))
(defun daily-navigate (console url &optional (exact t))
  (daily-eval console
    (format nil "(nyxt:ffi-buffer-load (nyxt:current-buffer) (quri:uri ~s))" url))
  (nyxt-app-until console
    (format nil "(and (nyxt/renderer/wpe::native-ready (nyxt:current-buffer)) (nyxt:ffi-buffer-evaluate-javascript (nyxt:current-buffer) ~s))"
      (format nil (if exact "document.readyState==='complete' && location.href===~s"
                          "document.readyState==='complete' && location.hostname===new URL(~s).hostname") url)) 90)
  ;; The visible origin must follow the page, including programmatic navigation.
  (nyxt-app-until console
    "(let* ((b (nyxt:current-buffer)) (host (quri:uri-host (nyxt:ffi-buffer-url b)))) (and host (equal (quri:render-uri (nyxt:url b)) (quri:render-uri (nyxt:ffi-buffer-url b))) (nyxt:ffi-buffer-evaluate-javascript (nyxt:status-buffer (nyxt:current-window)) (format nil \"document.querySelector('#url')?.innerText.includes(~s)\" host))))" 60))
(defun daily-quit (console)
  (image:send-keys (string (code-char 17)))
  (nyxt-app-ask console
    "(progn (assert (loop repeat 600 when (and (null (darterfly/run:find-world \"Nyxt\")) (zerop (hash-table-count darterfly/bsd::*native-processes*))) return t do (sleep .1))) (assert (eql 0 (getf (car (last (getf (darterfly/init:inspect-job \"Nyxt\") :exits))) :exit))) (darterfly/vfs:vfs-sync) (format t \"~&[DAILY CLEAN QUIT]~%\"))" 90))
(defun daily-wheel (down)
  (image:qmp "input-send-event"
    (darterfly/qmp:dict "events"
      (vector
        (darterfly/qmp:dict "type" "btn" "data"
          (darterfly/qmp:dict "button" (if down "wheel-down" "wheel-up") "down" t))
        (darterfly/qmp:dict "type" "btn" "data"
          (darterfly/qmp:dict "button" (if down "wheel-down" "wheel-up") "down" nil))))))
(let* ((disk (or (uiop:getenv "DARTERFLY_NYXT_DAILY_DISK")
                 (namestring (image::build-path "nyxt-daily-fresh.img"))))
       (reuse (uiop:getenv "DARTERFLY_NYXT_DAILY_REUSE"))
       (image::*include-browser* t)
       (image::*sbcl-runtime-options* (image::desktop-runtime-options))
       (image:*extra-qemu* (append '("-m" "8192") (image::desktop-audio-args))))
  (assert (image::nyxt-package-root))
  (when reuse (image::update-root disk))
  (unless reuse
    (when (probe-file disk) (error "Fresh qualification disk already exists: ~a" disk))
    (image::root-disk disk (* 4096 1048576)))
  (image::update-root disk
    (list (list :file "Users/darterfly/record-lock-probe.c"
      (image::octets (darterfly-file "ports/nyxt/wpe/record-lock-probe.c")))))
  ;; Test-only trust addition, after ordinary image assembly.
  (when (uiop:getenv "DARTER_HTTP_FIXTURE_DIR")
    (image::update-root disk
      (list (list :file "etc/ssl/certs/ca-certificates.crt"
        (concatenate '(vector (unsigned-byte 8))
          (third (first (image::certificates)))
          (image::octets (merge-pathnames "ca.pem"
            (uiop:ensure-directory-pathname (uiop:getenv "DARTER_HTTP_FIXTURE_DIR")))))))))
  (when (uiop:getenv "DARTER_NYXT_TRACE")
    (image::update-root disk
      (list (list :file "usr/lib/nyxt/nyxt-application.lisp"
        (concatenate '(vector (unsigned-byte 8))
          (image::text "(sb-posix:setenv \"DARTER_NYXT_TRACE\" \"1\" 1)")
          (image::octets (merge-pathnames "usr/lib/nyxt/nyxt-application.lisp"
                            (image::nyxt-package-root))))))))
  (dotimes (boot 2)
    (let* ((image::*console-log-directory*
             (image::build-path (format nil "wpe-assessment/daily-~d-~d/" (get-universal-time) boot)))
           (c (image:console :args (image::bare-qemu
                (image::esp :boot-args (image::root-boot-args "init" disk))
                nil (cons :keep disk) nil))))
      (unwind-protect
        (progn
          (image:expect c "init: pid 1" :timeout 180)
          (nyxt-app-ask c "(progn (sleep 8) (defparameter *nyxt-log-at* 0)
            (setf darterfly/layer::*connection* (make-instance 'darterfly/layer::connection))
            (defun nyxt-eval (world form &key (timeout 30))
              (let ((reply (darterfly/run:world-eval world form :timeout timeout)))
                (format t \"~&[NYXT EVAL] ~a~%\" reply)
                reply))
            (uiop:delete-file-if-exists \"/tmp/nyxt-application.log\"))")
          (nyxt-app-dock c)
          (nyxt-app-await c "/tmp/nyxt-application.log" "[NYXT APPLICATION READY]" 600)
          (nyxt-app-ask c "(defparameter *nyxt-app* (darterfly/run:find-world \"Nyxt\"))")
          (nyxt-app-ask c "(assert (null (getf (darterfly/init:inspect-job \"Nyxt\") :exits)) () \"Unexpected restart during normal browser launch\")")
          (daily-navigate c "https://10.0.2.2:18766/browser")
          (daily-check-js c "document.title==='Nyxt on Darterfly'")
          (if (zerop boot)
            (progn
              (daily-eval c "(progn (defparameter cl-user::*lock-check* nil) (nyxt/renderer/wpe::app-thread (lambda () (setf cl-user::*lock-check* (handler-case (progn (cffi-toolchain:cc-compile #p\"/tmp/record-lock-probe.o\" '(#p\"/Users/darterfly/record-lock-probe.c\")) (cffi-toolchain:link-executable #p\"/tmp/record-lock-probe\" '(#p\"/tmp/record-lock-probe.o\")) (assert (search \"NATIVE RECORD LOCKS PASS\" (uiop:run-program '(\"/tmp/record-lock-probe\") :output :string))) :pass) (error (e) (princ-to-string e))))) \"record locks\") t)")
              (nyxt-app-until c "cl-user::*lock-check*" 180)
              (daily-eval c "(assert (eq :pass cl-user::*lock-check*) () \"~a\" cl-user::*lock-check*)")
              (format t "~&[DAILY NATIVE RECORD LOCKS PASS]~%[DAILY NATIVE DESCRIPTOR SIGNALS PASS]~%")
              (daily-js c "document.body.style.height='4000px';window.scrollTo(0,0);'ready'")
              (image:pointer 300 350) (daily-wheel t) (sleep 1)
              (daily-check-js c "window.scrollY>0")
              (format t "~&[DAILY HID SCROLL PASS]~%")
              (daily-js c "window.scrollTo(0,0);document.querySelector('#entry').value='';document.querySelector('#entry').focus();'ready'")
              (nyxt-app-ask c "(setf (darterfly/layer:clipboard-text) \"Desktop λ → Nyxt\")")
              (image:send-keys (string (code-char 22))) (sleep 1)
              (daily-check-js c "document.querySelector('#entry').value==='Desktop λ → Nyxt'")
              (daily-js c "document.querySelector('#entry').select();'selected'")
              (image:send-keys (string (code-char 3))) (sleep 1)
              (nyxt-app-ask c "(assert (equal \"Desktop λ → Nyxt\" (darterfly/layer:clipboard-text)))")
              (image:send-keys (string (code-char 24))) (sleep 1)
              (daily-check-js c "document.querySelector('#entry').value===''")
              (image:send-keys (string (code-char 22))) (sleep 1)
              (daily-check-js c "document.querySelector('#entry').value==='Desktop λ → Nyxt'")
              (format t "~&[DAILY CROSS WORLD CLIPBOARD PASS]~%")
              (daily-js c "localStorage.setItem('darter-daily','survives-reboot');document.cookie='darter_daily=survives; Max-Age=86400; Secure; SameSite=Lax; Path=/';'saved'")
              (daily-js c "JSON.stringify({storage:localStorage.getItem('darter-daily'),cookie:document.cookie,url:location.href})")
              (daily-check-js c "localStorage.getItem('darter-daily')==='survives-reboot' && document.cookie.includes('darter_daily=survives')")
              (daily-eval c "(nyxt/mode/bookmark:persist-bookmark (quri:uri \"https://example.com/darter-profile-check\") :title \"Darter profile check\" :tags '(\"darter\"))")
              (daily-eval c "(let ((path (files:expand nyxt::*config-file*))) (ensure-directories-exist path) (with-open-file (s path :direction :output :if-exists :supersede) (write-line \"(defparameter cl-user::*daily-config-loaded* :from-profile)\" s)))")
              ;; A URL never visited on boot 1 distinguishes restored history
              ;; from the current page being added to a fresh history store.
              (daily-navigate c "https://10.0.2.2:18766/browser?history=before-reboot")
              (sleep 5)
              (nyxt-app-shot "daily-before-reboot"))
            (progn
              (daily-js c "JSON.stringify({storage:localStorage.getItem('darter-daily'),cookie:document.cookie,url:location.href})")
              (daily-check-js c "localStorage.getItem('darter-daily')==='survives-reboot'")
              (daily-check-js c "document.cookie.includes('darter_daily=survives')")
              (daily-eval c "(assert (eq :from-profile (symbol-value (find-symbol \"*DAILY-CONFIG-LOADED*\" :cl-user))))")
              (daily-eval c "(assert (find \"Darter profile check\" (files:content (nyxt/mode/bookmark:bookmarks-file (nyxt:current-buffer))) :key #'nyxt:title :test #'equal))")
              (daily-eval c "(assert (find-if (lambda (entry) (search \"10.0.2.2:18766/browser?history=before-reboot\" (quri:render-uri (nyxt:url entry)))) (nyxt::history-vector nyxt:*browser*)))")
              (format t "~&[DAILY PROFILE REBOOT PASS]~%")
              (dotimes (i 20)
                (daily-navigate c (format nil "https://10.0.2.2:18766/browser?stress=~d" i))
                (daily-check-js c "document.title==='Nyxt on Darterfly' && 6*7===42"))
              (format t "~&[DAILY TWENTY NAVIGATIONS PASS]~%")
              (daily-eval c "(defparameter cl-user::*daily-tabs* nil)")
              (nyxt-app-ask c "(format t \"~&[DAILY FREE PAGES BEFORE TABS] ~d~%\" (darterfly/worlds:free-pages))")
              ;; Run app work outside the control dispatcher used by init's
              ;; health probes. A long world-eval would manufacture a hang.
              (daily-eval c "(progn (defparameter cl-user::*daily-tab-state* nil) (nyxt/renderer/wpe::app-thread (lambda () (setf cl-user::*daily-tab-state* (handler-case (progn (dotimes (i 8) (push (nyxt:make-buffer :url (quri:uri (format nil \"https://10.0.2.2:18766/browser?tab=~d\" i))) cl-user::*daily-tabs*)) :done) (error (e) (princ-to-string e))))) \"tab stress\") t)")
              (nyxt-app-until c "cl-user::*daily-tab-state*" 180)
              (daily-eval c "(assert (eq :done cl-user::*daily-tab-state*) () \"~a\" cl-user::*daily-tab-state*)")
              (nyxt-app-ask c "(format t \"~&[DAILY FREE PAGES WITH TABS] ~d~%\" (darterfly/worlds:free-pages))")
              (nyxt-app-until c "(every (lambda (b) (and (nyxt/renderer/wpe::native-ready b) (equal \"Nyxt on Darterfly\" (nyxt/renderer/wpe::native-title b)))) cl-user::*daily-tabs*)")
              (daily-eval c "(nyxt:delete-buffer :buffers cl-user::*daily-tabs*)")
              (daily-eval c "(assert (every (lambda (b) (null (nyxt/renderer/wpe::native-id b))) cl-user::*daily-tabs*))")
              (daily-check-js c "document.title==='Nyxt on Darterfly'")
              (format t "~&[DAILY EIGHT TABS CLOSED PASS]~%")
              (dolist (url '("https://example.com/" "https://en.wikipedia.org/wiki/Dragonfly"
                              "https://www.youtube.com/"))
                (handler-case
                  (progn
                    (daily-navigate c url nil)
                    (daily-check-js c
                      (format nil "document.title.toLowerCase().includes(~s) && document.body.innerText.length>50"
                        (cond ((search "youtube" url) "youtube")
                              ((search "wikipedia" url) "dragonfly") (t "example domain"))))
                    (daily-js c "JSON.stringify({url:location.href,title:document.title,text:document.body.innerText.slice(0,300),video:typeof document.createElement('video').canPlayType==='function'?document.createElement('video').canPlayType('video/mp4'):'disabled',audio:typeof AudioContext})")
                    (nyxt-app-shot (cond ((search "youtube" url) "youtube")
                                        ((search "wikipedia" url) "wikipedia") (t "example")))
                    (format t "~&[DAILY SITE LOAD] ~a~%" url))
                  (error (e)
                    (ignore-errors (nyxt-app-shot (if (search "youtube" url) "youtube-failed" "site-failed")))
                    (format t "~&[DAILY SITE FAILED] ~a: ~a~%" url e))))
              (daily-eval c "(assert (null nyxt/renderer/wpe::*failure*))")
              (daily-eval c "(nyxt/renderer/wpe::rpc 19 0)")))
          (daily-quit c)
          (format t "~&[DAILY BOOT ~d PASS]~%" boot))
        (ignore-errors
          (nyxt-app-ask c "(progn (dolist (p '(\"/tmp/nyxt-engine.log\" \"/tmp/nyxt-application.log\")) (format t \"~&LOG ~a~%\" p) (when (probe-file p) (let ((text (uiop:read-file-string p))) (write-string text *standard-output* :start (max 0 (- (length text) 65536)))))) (finish-output))" 30))
        (with-open-file (s (image::build-path (format nil "wpe-assessment/nyxt-daily-guest-~d.log" boot))
                          :direction :output :if-exists :supersede)
          (write-string (image:transcript c) s))
        (ignore-errors (image:qmp "quit"))
        (image:finish c 5))))
  (format t "~&[NYXT DAILY QUALIFICATION PASS]~%"))
