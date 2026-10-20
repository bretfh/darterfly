(require :asdf)
(asdf:load-system :darterfly/test)
(load (asdf:system-relative-pathname :darterfly "ports/nyxt/wpe/application-image.lisp"))
(in-package #:darterfly/test)
(declaim (ftype (function (t) t) nyxt-crash-checks))
(defun nyxt-app-ask (console form &optional (timeout 90))
  (image:send console form)
  (let ((out (image:expect console (list (format nil "~%* ") "debugger invoked") :timeout timeout)))
    (when (search "debugger invoked" out) (error "Guest: ~a" out)) out))
(defun nyxt-app-await (console path marker &optional (seconds 180))
  (image:send console
    (format nil
      "(loop repeat ~d for log = (ignore-errors (uiop:read-file-string ~s)) do (when log (write-string log *standard-output* :start (min *nyxt-log-at* (length log))) (setf *nyxt-log-at* (length log)) (finish-output)) when (and log (or (search ~s log) (search \"[NYXT APPLICATION FAILED]\" log) (search \"[NYXT APP CHECK FAILED]\" log))) return t do (sleep .2) finally (format t \"~%[NYXT APP TIMEOUT]~%\"))"
      (* seconds 5) path marker))
  (let ((out (image:expect console (list marker "[NYXT APPLICATION FAILED]"
                                        "[NYXT APP CHECK FAILED]" "[NYXT APP TIMEOUT]"
                                        "debugger invoked") :timeout (+ seconds 10))))
    (image:expect console (format nil "~%* ") :timeout 15)
    (unless (search marker out)
      (error "Nyxt app did not reach ~a: ~a" marker out))))
(defun nyxt-app-until (console predicate &optional (seconds 60))
  (nyxt-app-ask console
    (format nil "(nyxt-eval *nyxt-app* ~s :timeout ~d)"
      (format nil "(assert (loop repeat ~d when ~a return t do (sleep .1)))"
        (* seconds 10) predicate) (+ seconds 10)) (+ seconds 20)))
(defun nyxt-app-dock (console)
  ;; Read Harbor's current logical layout; exercise its real HID click path.
  (let* ((out (nyxt-app-ask console
           "(destructuring-bind (dx dy width height) (darterfly/layer:main-display-bounds)
              (declare (ignore dx dy))
              (let* ((layout (darterfly/layer:dock-layout
                               (darterfly/kit::all-window-descriptions) width height))
                     (item (find \"Nyxt\" (getf layout :items)
                                 :key (lambda (i) (getf i :key)) :test #'equal))
                     (outer (getf layout :frame)) (inner (getf item :frame)))
                (assert item)
                (format t \"~&[NYXT DOCK POINT] ~s~%\"
                  (list (+ (first outer) (first inner) (floor (third inner) 2))
                        (+ (second outer) (second inner) (floor (fourth inner) 2))))))"))
         (marker "[NYXT DOCK POINT] ")
         (at (search marker out :from-end t)))
    (assert at)
    (let* ((*read-eval* nil)
           (point (read-from-string out nil nil :start (+ at (length marker)))))
      (destructuring-bind (x y) point
        (image:pointer x y t) (sleep .15) (image:pointer x y nil)))))

(defun nyxt-app-shot (name)
  (image:screendump)
  (uiop:copy-file (darterfly-file "build/screen.ppm")
    (darterfly-file (format nil "build/wpe-assessment/nyxt-app-~a.ppm" name))))

(let* ((root (uiop:ensure-directory-pathname
              (string-trim '(#\Newline #\Return #\Space)
                (uiop:read-file-string (darterfly-file "build/wpe-assessment/render-build-root.txt")))))
       (dir (merge-pathnames "nyxt-build/" root))
       (disk (if (uiop:getenv "DARTERFLY_NYXT_APP_DISK")
                 (pathname (uiop:getenv "DARTERFLY_NYXT_APP_DISK"))
                 (merge-pathnames "nyxt-app.img" dir))))
  (when (and (probe-file disk) (image::in-use-p disk)) (error "App disk is in use"))
  ;; Seed the qualified source closure once; never overwrite it on a retry.
  (unless (probe-file disk)
    (uiop:copy-file (merge-pathnames "nyxt-browser.img" dir) disk))
  (let ((entries
          (append (image::root-entries) (image::nyxt-application-entries root)
            (list (list :file "Users/darterfly/nyxt-browser-checks.lisp"
                    (image::octets (darterfly-file "ports/nyxt/wpe/nyxt-browser-checks.lisp"))))
            (when (uiop:getenv "DARTERFLY_NYXT_DISPATCH")
              (list (list :file "Users/darterfly/nyxt-dispatch-checks.lisp"
                      (image::octets (darterfly-file "ports/nyxt/wpe/nyxt-dispatch-checks.lisp")))))
            ;; Only the test disk trusts this fixture CA. Installed app code
            ;; and package entries use the regular system trust store.
            (when (uiop:getenv "DARTER_HTTP_FIXTURE_DIR")
              (list (list :file "etc/ssl/certs/ca-certificates.crt"
                (concatenate '(vector (unsigned-byte 8))
                  (third (first (image::certificates)))
                  (image::octets (merge-pathnames "ca.pem"
                    (uiop:ensure-directory-pathname (uiop:getenv "DARTER_HTTP_FIXTURE_DIR")))))))))))
    (image::update-root disk (image::with-entry-directories entries)))
  (let* ((image::*sbcl-runtime-options* '("--dynamic-space-size" "2048"))
         (image:*extra-qemu* (append '("-m" "8192") image:*extra-qemu*))
         (image::*console-log-directory*
           (merge-pathnames (format nil "app-console-~d-~d/" (get-universal-time) (sb-posix:getpid)) dir))
         ;; The image was updated above. BARE-CONSOLE would update it again
         ;; and replace the test trust store with the unmodified system bundle.
         (c (image:console :args
              (image::bare-qemu
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
              (assert (not (search \"error: \" reply))) reply)) :app-test-ready)")
        (when (uiop:getenv "DARTER_HTTP_FIXTURE_DIR")
          (nyxt-app-ask c
            (format nil "(progn (assert (search ~s (uiop:read-file-string \"/etc/ssl/certs/ca-certificates.crt\"))) (format t \"~&[NYXT APP TEST TRUST STORE PASS]~%\"))"
              (uiop:read-file-string (merge-pathnames "ca.pem"
                (uiop:ensure-directory-pathname (uiop:getenv "DARTER_HTTP_FIXTURE_DIR")))))))
        (unless (uiop:getenv "DARTERFLY_NYXT_RECOVERY_ONLY")
        ;; Launch through the installed Nyxt Dock item: the actual desktop event
        ;; follows open-application -> init -> app world -> registered program.
        (nyxt-app-dock c)
        (nyxt-app-await c "/tmp/nyxt-application.log" "[NYXT APPLICATION READY]" 240)
        (nyxt-app-ask c
          "(progn (defparameter *nyxt-app* (darterfly/run:find-world \"Nyxt\"))
            (assert *nyxt-app*)
            (assert (find \"Nyxt\" (darterfly/init:jobs) :key (lambda (j) (getf j :label)) :test #'equal))
            (assert (gethash (darterfly/run:world-id *nyxt-app*) darterfly/layer::*world-clients*))
            (assert (not (probe-file \"/tmp/nyxt-windows.sock\")))
            (format t \"~&[NYXT NORMAL APP WORLD PASS]~%\"))")
        (nyxt-app-shot "blank")
        (nyxt-app-dock c)
        (nyxt-app-ask c "(progn (sleep 1) (assert (eq *nyxt-app* (darterfly/run:find-world \"Nyxt\"))) (assert (null (darterfly/run:find-world \"Nyxt 2\"))) (format t \"~&[NYXT APP SINGLE INSTANCE PASS]~%\"))")
        ;; Navigation is real HID through Nyxt's own prompt, not a test-only
        ;; startup URL or a synthetic DOM event.
        (nyxt-app-ask c "(nyxt-eval *nyxt-app* \"(progn (defvar cl-user::*nyxt-prompt-ready* nil) (defun cl-user::nyxt-test-prompt-ready (p) (setf cl-user::*nyxt-prompt-ready* p)) (nhooks:add-hook (nyxt::prompt-buffer-ready-hook nyxt:*browser*) 'cl-user::nyxt-test-prompt-ready))\")")
        (image:send-keys (string (code-char 12)))
        (nyxt-app-until c "(let ((p (nyxt:current-prompt-buffer))) (and p (eq p cl-user::*nyxt-prompt-ready*) (plusp (nyxt/renderer/wpe::native-frame-count p)) (nyxt:ffi-buffer-evaluate-javascript p \"!!document.querySelector('#input')\")))")
        (image:send-keys "https://10.0.2.2:18766/browser")
        (nyxt-app-until c "(let ((p (nyxt:current-prompt-buffer))) (and p (equal \"https://10.0.2.2:18766/browser\" (prompter:input p))))")
        ;; Input text precedes the asynchronous suggestion result. Wait for
        ;; the selected URL that Enter will actually submit.
        (nyxt-app-until c "(let ((p (nyxt:current-prompt-buffer))) (and p (ignore-errors (equal \"https://10.0.2.2:18766/browser\" (quri:render-uri (nyxt:url (nyxt:current-suggestion-value p)))))))")
        (image:send-keys (string #\Newline))
        (nyxt-app-ask c
          "(progn (setf *nyxt-log-at* 0)
            (nyxt-eval *nyxt-app*
              \"(sb-thread:make-thread (lambda () (with-open-file (log \\\"/tmp/nyxt-app-checks.log\\\" :direction :output :if-exists :supersede) (let ((*standard-output* log) (*error-output* log) (*trace-output* log)) (handler-case (load \\\"/Users/darterfly/nyxt-browser-checks.lisp\\\") (error (e) (format log \\\"~&[NYXT APP CHECK FAILED] ~a~%\\\" e) (sb-debug:print-backtrace :stream log :count 25))) (finish-output log)))) :name \\\"browser qualification\\\")\" :timeout 30) t)")
        (nyxt-app-await c "/tmp/nyxt-app-checks.log" "[NYXT BROWSER INPUT READY]" 240)
        (image:pointer 180 258 t) (sleep .2) (image:pointer 180 258 nil)
        (image:send-keys "darter")
        (nyxt-app-await c "/tmp/nyxt-app-checks.log" "[NYXT BROWSER PROMPT REQUEST]")
        (nyxt-app-shot "input")
        (image:send-keys (string (code-char 12)))
        (nyxt-app-await c "/tmp/nyxt-app-checks.log" "[NYXT BROWSER PROMPT READY]")
        (nyxt-app-shot "prompt")
        (image:send-keys "https://10.0.2.2:18766/browser?navigation=2")
        (nyxt-app-await c "/tmp/nyxt-app-checks.log" "[NYXT BROWSER NAVIGATE READY]")
        (image:send-keys (string #\Newline))
        (nyxt-app-await c "/tmp/nyxt-app-checks.log" "[NYXT BROWSER SCREENSHOT READY]")
        (nyxt-app-shot "page")
        (nyxt-app-await c "/tmp/nyxt-app-checks.log" "[NYXT BROWSER QUALIFICATION PASS]")
        ;; Harbor discovers the real browser window and receives its title.
        (nyxt-app-ask c
          "(progn
             (defparameter *nyxt-harbor-window*
               (find \"Nyxt\" (darterfly/kit::all-window-descriptions)
                 :key (lambda (w) (getf w :app)) :test #'equal))
             (assert *nyxt-harbor-window*)
             (assert (not (equal \"Untitled window\" (getf *nyxt-harbor-window* :title))))
             (nyxt-eval *nyxt-app*
               \"(assert (find \\\"Nyxt\\\" (darterfly/kit::all-window-descriptions) :key (lambda (w) (getf w :app)) :test #'equal))\")
             (format t \"~&[NYXT HARBOR DISCOVERY PASS]~%\"))")
        ;; Resize through WindowServer's actual pointer edge drag.
        (image:pointer 718 558 t) (sleep .15)
        (image:pointer 798 598 t) (sleep .15) (image:pointer 798 598 nil)
        (nyxt-app-until c "(let ((w (nyxt:current-window))) (and (= 720 (nyxt/renderer/wpe::native-width w)) (= 520 (nyxt/renderer/wpe::native-height w))))")
        (nyxt-app-ask c
          "(progn
             (darterfly/windowserver::apply-transaction
               (list (list :minimize (second (getf *nyxt-harbor-window* :handle)) t)))
             (assert (getf (find \"Nyxt\" (darterfly/kit::all-window-descriptions)
               :key (lambda (w) (getf w :app)) :test #'equal) :minimized)))")
        (nyxt-app-dock c)
        (nyxt-app-ask c
          "(progn (sleep 1)
             (let ((w (find \"Nyxt\" (darterfly/kit::all-window-descriptions)
                        :key (lambda (w) (getf w :app)) :test #'equal)))
               (assert w) (assert (not (getf w :minimized))) (assert (getf w :active)))
             (format t \"~&[NYXT HARBOR RESIZE RESTORE PASS]~%\"))")
        (when (uiop:getenv "DARTERFLY_NYXT_DISPATCH")
          (nyxt-app-ask c
            "(unwind-protect (nyxt-eval *nyxt-app* \"(with-open-file (s \\\"/tmp/nyxt-dispatch-checks.log\\\" :direction :output :if-exists :supersede) (let ((*standard-output* s) (*error-output* s)) (load \\\"/Users/darterfly/nyxt-dispatch-checks.lisp\\\")))\" :timeout 180) (write-string (uiop:read-file-string \"/tmp/nyxt-dispatch-checks.log\")) (finish-output))" 200)
          (format t "~&[NYXT DISPATCH QUALIFICATION PASS]~%"))
        (image:send-keys (string (code-char 17)))
        (nyxt-app-ask c
          "(progn (loop repeat 300 until (and (eq :stopped (getf (darterfly/init:inspect-job \"Nyxt\") :state)) (null (darterfly/run:find-world \"Nyxt\")) (zerop (hash-table-count darterfly/bsd::*native-processes*)) (null (gethash (darterfly/run:world-id *nyxt-app*) darterfly/layer::*world-clients*))) do (sleep .1))
            (assert (null (darterfly/run:find-world \"Nyxt\")))
            (assert (null (gethash (darterfly/run:world-id *nyxt-app*) darterfly/layer::*world-clients*)))
            (assert (zerop (hash-table-count darterfly/bsd::*native-processes*)))
            (let ((exit (car (last (getf (darterfly/init:inspect-job \"Nyxt\") :exits)))))
              (assert (eql 0 (getf exit :exit))))
            (format t \"~&[NYXT APP CLEANUP PASS]~%\"))")
        ;; Relaunch via the same Dock, then quit through upstream Nyxt's C-q.
        (nyxt-app-ask c "(progn (setf *nyxt-log-at* 0) (uiop:delete-file-if-exists \"/tmp/nyxt-application.log\"))")
        (nyxt-app-dock c)
        (nyxt-app-await c "/tmp/nyxt-application.log" "[NYXT APPLICATION READY]" 240)
        (nyxt-app-ask c
          "(progn (setf *nyxt-app* (darterfly/run:find-world \"Nyxt\")) (assert *nyxt-app*)
             (format t \"~&[NYXT APP RELAUNCH PASS]~%\"))")
        (image:send-keys (string (code-char 17)))
        (nyxt-app-ask c
          "(progn (loop repeat 300 until (and (eq :stopped (getf (darterfly/init:inspect-job \"Nyxt\") :state)) (null (darterfly/run:find-world \"Nyxt\")) (zerop (hash-table-count darterfly/bsd::*native-processes*)) (null (gethash (darterfly/run:world-id *nyxt-app*) darterfly/layer::*world-clients*))) do (sleep .1))
            (assert (null (darterfly/run:find-world \"Nyxt\")))
            (assert (zerop (hash-table-count darterfly/bsd::*native-processes*)))
            (assert (null (gethash (darterfly/run:world-id *nyxt-app*) darterfly/layer::*world-clients*)))
            (let ((exit (car (last (getf (darterfly/init:inspect-job \"Nyxt\") :exits)))))
              (assert (eql 0 (getf exit :exit))))
            (format t \"~&[NYXT APP QUIT PASS]~%\"))")
        (format t "~&[NYXT APP QUALIFICATION PASS]~%"))
        (when (uiop:getenv "DARTERFLY_NYXT_RECOVERY")
          (load (darterfly-file "ports/nyxt/wpe/nyxt-crash-checks.lisp"))
          (nyxt-crash-checks c))
        ;; An app cleanup marker must not hide a stopped supervisor worker.
        (let ((transcript (image:transcript c)))
          ;; TRANSCRIPT consumes the capture stream. Preserve it for the
          ;; unwind-protect export, including when validation signals an error.
          (write-string transcript (image::console-seen c))
          (when (or (search "panic(" transcript)
                    (search "debugger invoked" transcript)
                    (search (format nil "~%stopped ") transcript))
            (error "Browser run left a kernel/supervisor failure; inspect guest transcript")))
        (when (and (uiop:getenv "DARTERFLY_NYXT_DISPATCH")
                   (uiop:getenv "DARTERFLY_NYXT_RECOVERY")
                   (not (uiop:getenv "DARTERFLY_NYXT_RECOVERY_ONLY")))
          (format t "~&[NYXT COMBINED QUALIFICATION PASS]~%")))
      (ignore-errors
        (nyxt-app-ask c
          "(progn (write-string (or (ignore-errors (uiop:read-file-string \"/tmp/nyxt-application.log\")) \"\")) (finish-output))" 20))
      (with-open-file (s (darterfly-file "build/wpe-assessment/nyxt-app-guest.log")
                        :direction :output :if-exists :supersede)
        (write-string (image:transcript c) s))
      (image:finish c 5))))
