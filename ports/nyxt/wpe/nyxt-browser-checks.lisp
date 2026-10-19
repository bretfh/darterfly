(in-package #:nyxt/renderer/wpe)
(defun await-check (name thunk &optional (seconds 60))
  (loop for tick below (* seconds 20)
        when *failure* do (error "~a: ~a" name *failure*)
        when (funcall thunk) do
          (format t "~&[NYXT BROWSER ~a PASS]~%" name) (finish-output)
          (return-from await-check t)
        do (sleep .05))
  (error "Timed out: ~a" name))
(defvar *keep-browser-open* (not (null nyxt:*browser*)))
(setf nyxt::*run-from-repl-p* t)
(unless nyxt:*browser*
  (launch '("https://10.0.2.2:18766/browser") :online-suggestions nil))
(await-check "NORMAL STARTUP"
  (lambda ()
    (and (nyxt:current-window)
         (nyxt:current-buffer)
         (native-navigation (nyxt:current-buffer)))))
(defparameter *test-window* (nyxt:current-window))
(defparameter *test-buffer* (nyxt:current-buffer))
(await-check "HTTPS PAGE"
  (lambda () (and (native-ready *test-buffer*)
                 (string= "Nyxt on Darterfly" (native-title *test-buffer*)))) 60)
(await-check "NATIVE FRAME" (lambda () (> (native-frame-count *test-buffer*) 0)))
(assert (equal 42 (nyxt:ffi-buffer-evaluate-javascript *test-buffer* "6*7")))
(format t "~&[NYXT BROWSER JAVASCRIPT PASS]~%")
(defparameter *callback-probe* nil)
(let* ((chrome (nyxt:status-buffer *test-window*))
       (uri (quri:render-uri
             (nyxt::lisp-url :buffer chrome :title "Darterfly callback regression"
               :callback (lambda () (setf *callback-probe* t)))))
       (javascript (format nil
         "window.callbackDone=false;window.callbackError='';fetch(~a,{mode:'no-cors'}).then(()=>window.callbackDone=true).catch(e=>{window.callbackError=String(e);window.callbackDone=true})"
         (j:encode uri))))
  (nyxt:ffi-buffer-evaluate-javascript-async chrome javascript)
  (await-check "TRUSTED CALLBACK REQUEST FINISHED"
    (lambda () (nyxt:ffi-buffer-evaluate-javascript chrome "window.callbackDone===true")))
  (assert *callback-probe* () "Trusted callback did not execute: ~a"
          (nyxt:ffi-buffer-evaluate-javascript chrome "window.callbackError"))
  (format t "~&[NYXT BROWSER TRUSTED LISP CALLBACK PASS]~%")
  (setf *callback-probe* nil)
  (nyxt:ffi-buffer-evaluate-javascript-async *test-buffer* javascript)
  (await-check "WEB CALLBACK REQUEST FINISHED"
    (lambda () (nyxt:ffi-buffer-evaluate-javascript *test-buffer* "window.callbackDone===true")))
  (assert (not *callback-probe*))
  (format t "~&[NYXT BROWSER WEB CALLBACK DENIED PASS]~%"))
(format t "~&[NYXT BROWSER INPUT READY]~%") (finish-output)
;; The host sends real QEMU HID input. No synthetic DOM events satisfy this.
(await-check "POINTER AND KEYBOARD"
  (lambda () (equal "darter" (nyxt:ffi-buffer-evaluate-javascript
    *test-buffer* "document.querySelector('#entry').value"))) 90)
(assert (>= *event-count* 8))
(assert (equal t (nyxt:ffi-buffer-evaluate-javascript *test-buffer*
  "window.realClicks > 0 && window.realKeys >= 6")))
(format t "~&[NYXT BROWSER TRUSTED INPUT PASS]~%")
(defparameter *ready-prompt* nil)
(defun qualification-prompt-ready (prompt) (setf *ready-prompt* prompt))
(nhooks:add-hook (nyxt::prompt-buffer-ready-hook nyxt:*browser*)
                 'qualification-prompt-ready)
(format t "~&[NYXT BROWSER PROMPT REQUEST]~%") (finish-output)
(await-check "URL PROMPT"
  (lambda ()
    (let ((prompt (nyxt:current-prompt-buffer)))
      (and prompt (eq prompt *ready-prompt*)
           (eq prompt (native-focus *test-window*))
           (plusp (native-frame-count prompt))
           (nyxt:ffi-buffer-evaluate-javascript prompt
             "!!document.querySelector('#input')")))))
(defparameter *test-prompt* (nyxt:current-prompt-buffer))
(format t "~&[NYXT BROWSER PROMPT READY]~%") (finish-output)
(defparameter *next-url* "https://10.0.2.2:18766/browser?navigation=2")
(await-check "PROMPT TEXT"
  (lambda ()
    (let ((prompt (nyxt:current-prompt-buffer)))
      (and prompt (equal *next-url* (prompter:input prompt))
           (ignore-errors
             (equal *next-url* (quri:render-uri
               (nyxt:url (nyxt:current-suggestion-value prompt)))))))))
(format t "~&[NYXT BROWSER NAVIGATE READY]~%") (finish-output)
(await-check "COMMAND NAVIGATION"
  (lambda ()
    (and (null (nyxt:current-prompt-buffer))
         (native-ready *test-buffer*)
         (equal *next-url* (native-url *test-buffer*)))))
;; A completed background suggestion must not resurrect a dismissed prompt
;; or send NIL as its native object ID.
(assert (null (native-id *test-prompt*)))
(nyxt:ffi-buffer-evaluate-javascript-async *test-prompt*
  "throw new Error('obsolete prompt update must not execute')")
(assert (equal 42 (nyxt:ffi-buffer-evaluate-javascript *test-buffer* "6*7")))
(assert (null *failure*))
(format t "~&[NYXT BROWSER LATE PROMPT UPDATE PASS]~%")
;; Keep a visible result for the screenshot before orderly child shutdown.
(format t "~&[NYXT BROWSER SCREENSHOT READY]~%") (finish-output)
(sleep 5)
(unless *keep-browser-open* (ffi-kill-browser nyxt:*browser*))
(format t "~&[NYXT BROWSER QUALIFICATION PASS]~%") (finish-output)
