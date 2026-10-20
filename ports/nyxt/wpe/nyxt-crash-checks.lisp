;;;; Host-driven destructive tests, only inside the harness-owned QEMU.
;;;; No failure injection is installed in the application package.
(in-package #:darterfly/test)
(defun nyxt-crash-checks (c)
  (nyxt-app-ask c
    "(progn
       (defvar *nyxt-app* nil) (defvar *crash-old* nil) (defvar *crash-native* nil)
       (defun crash-ready ()
         (let ((w (darterfly/run:find-world \"Nyxt\")))
           (when (and w (not (eq w *crash-old*)))
             (when (ignore-errors
               (equal \":READY\" (string-trim '(#\\Space #\\Newline)
                 (darterfly/run:world-eval w
                   \"(when (and (find-package :nyxt/renderer/wpe)
                              (boundp 'nyxt:*browser*) nyxt:*browser*
                              (lparallel:fulfilledp (slot-value nyxt:*browser* 'nyxt::startup-promise))
                              (nyxt:current-buffer)
                              (plusp (nyxt/renderer/wpe::native-frame-count
                                       (nyxt:current-buffer)))
                              (not nyxt/renderer/wpe::*failure*)
                              (not nyxt/renderer/wpe::*closing*)) :ready)\"
                   :timeout 2))))
               (setf *nyxt-app* w) t))))
       (defun crash-snapshot ()
         (setf *crash-old* *nyxt-app*
               *crash-native*
               (darterfly/bsd::with-bsd
                 (loop for id being the hash-keys of darterfly/bsd::*native-processes*
                       using (hash-value p)
                       when (member (darterfly/bsd::proc-comm p)
                                    '(\"nyxt-wpe-engine\" \"WPEWebProcess\" \"WPENetworkProcess\")
                                    :test #'equal)
                         collect (list id (darterfly/bsd:proc-pid p)
                                       (darterfly/bsd::proc-comm p)))))
         (assert (>= (length *crash-native*) 3)))
       (defun crash-cleaned ()
         (assert (null (gethash (darterfly/run:world-id *crash-old*)
                               darterfly/layer::*world-clients*)))
         (dolist (entry *crash-native*)
           (assert (null (gethash (first entry) darterfly/bsd::*native-processes*)))
           (assert (null (darterfly/bsd::pfind (second entry))))
           (assert (not (find (first entry) (darterfly/worlds:worlds)
                             :key (lambda (w) (getf w :id)))))))
       (defun crash-inject (name &optional hang)
         (crash-snapshot)
         (let ((entry (find name (sort (copy-list *crash-native*) #'< :key #'second) :key #'third :test #'equal)))
           (assert entry)
           (format t \"~&[NYXT CRASH INJECT ~a ~a]~%\" name (if hang :hang :kill))
           (finish-output)
           (if hang (darterfly/worlds:pause (first entry))
               (darterfly/bsd:kill (second entry) :sigkill))))
       (defun crash-diagnostic ()
         (format t \"~&[CRASH DIAGNOSTIC] ~s~%~s~%\"
           (darterfly/init:inspect-job \"Nyxt\") (darterfly/worlds:worlds))
         (finish-output))
       :crash-tests-ready)")
  (labels ((ready (marker)
             (nyxt-app-ask c
               (format nil "(progn (assert (loop for n below 120 when (crash-ready) return t do (when (and *crash-old* (zerop (mod n 15))) (crash-diagnostic)) (sleep 1))) (format t ~s))"
                 (format nil "~%[NYXT RECOVERY ~a READY]~%" marker)) 300))
           (check (n marker)
             (nyxt-app-ask c
               (format nil "(progn (assert (loop repeat 100 when (ignore-errors (crash-cleaned) t) return t do (sleep .1))) (assert (= ~d (length (getf (darterfly/init:inspect-job \"Nyxt\") :exits)))) (assert (eq :running (getf (darterfly/init:inspect-job \"Nyxt\") :state))) (format t ~s))"
                 n (format nil "~%[NYXT RECOVERY ~a CLEANUP PASS]~%" marker))))
           (failed (marker)
             (nyxt-app-ask c
               (format nil "(progn (assert (loop repeat 120 when (eq :failed (getf (darterfly/init:inspect-job \"Nyxt\") :state)) return t do (sleep 1))) (assert (loop repeat 100 when (ignore-errors (crash-cleaned) t) return t do (sleep .1))) (assert (null (darterfly/run:find-world \"Nyxt\"))) (assert (= 3 (length (getf (darterfly/init:inspect-job \"Nyxt\") :exits)))) (sleep 12) (assert (null (darterfly/run:find-world \"Nyxt\"))) (assert (zerop (hash-table-count darterfly/bsd::*native-processes*))) (format t ~s))"
                 (format nil "~%[NYXT RECOVERY ~a BUDGET PASS]~%" marker)) 150))
           (dock ()
             (image:pointer 776 744 t) (sleep .15) (image:pointer 776 744 nil)))
    (dock) (ready "INITIAL")
    (nyxt-app-ask c "(crash-inject \"nyxt-wpe-engine\")")
    (ready "UI") (check 1 "UI")
    ;; Recovery must still run real JavaScript over verified HTTPS.
    (nyxt-app-ask c "(nyxt-eval *nyxt-app* \"(nyxt:ffi-buffer-load (nyxt:current-buffer) (quri:uri \\\"https://10.0.2.2:18766/browser?recovery=1\\\"))\")")
    (nyxt-app-until c "(and (eq :finished (nyxt::status (nyxt:current-buffer))) (equal \"Nyxt on Darterfly\" (nyxt:ffi-buffer-evaluate-javascript (nyxt:current-buffer) \"document.title\")))" 90)
    (nyxt-app-ask c "(nyxt-eval *nyxt-app* \"(assert (= 42 (nyxt:ffi-buffer-evaluate-javascript (nyxt:current-buffer) \\\"6*7\\\")))\")")
    (format t "~&[NYXT RECOVERY HTTPS JAVASCRIPT PASS]~%")
    (nyxt-app-ask c "(crash-inject \"WPEWebProcess\")")
    (ready "WEB") (check 2 "WEB")
    (nyxt-app-ask c "(crash-inject \"WPENetworkProcess\")")
    (failed "ENGINE")
    ;; A manual launch resets the budget, without replacing the init job model.
    (dock) (ready "MANUAL")
    (nyxt-app-ask c "(progn (assert (null (getf (darterfly/init:inspect-job \"Nyxt\") :exits))) (crash-snapshot) (darterfly/worlds:stop (darterfly/run:world-id *crash-old*)))")
    (ready "LISP") (check 1 "LISP")
    ;; Pause the actual UI process: no EOF, so the bounded liveness/kill path
    ;; has to reclaim it rather than depending on a cooperative engine exit.
    (nyxt-app-ask c "(crash-inject \"nyxt-wpe-engine\" t)")
    (ready "HUNG-ENGINE") (check 2 "HUNG-ENGINE")
    ;; Pause the app itself. Only init's existing external health check can
    ;; recover this case; an in-app monitor cannot run in a paused world.
    (nyxt-app-ask c "(progn (crash-snapshot) (darterfly/worlds:pause (darterfly/run:world-id *crash-old*)))")
    (failed "HUNG-APP")
    (dock) (ready "FINAL")
    (nyxt-app-ask c "(progn (crash-snapshot) (nyxt-eval *nyxt-app* \"(bordeaux-threads:make-thread (lambda () (error \\\"Injected Nyxt worker failure\\\")) :name \\\"recovery worker probe\\\")\"))")
    (ready "WORKER") (check 1 "WORKER")
    (nyxt-app-ask c "(crash-snapshot)")
    (image:send-keys (string (code-char 17)))
    (nyxt-app-ask c
      "(progn (assert (loop repeat 60 when (eq :stopped (getf (darterfly/init:inspect-job \"Nyxt\") :state)) return t do (sleep 1))) (assert (loop repeat 100 when (ignore-errors (crash-cleaned) t) return t do (sleep .1))) (assert (eql 0 (getf (car (last (getf (darterfly/init:inspect-job \"Nyxt\") :exits))) :exit))) (sleep 12) (assert (null (darterfly/run:find-world \"Nyxt\"))) (assert (zerop (hash-table-count darterfly/bsd::*native-processes*))) (format t \"~&[NYXT RECOVERY NORMAL QUIT PASS]~%\"))" 90)
    (format t "~&[NYXT CRASH QUALIFICATION PASS]~%")))
