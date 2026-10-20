(in-package #:darterfly/test)
(declaim (ftype (function (t) t) nyxt-crash-checks))
(defvar *nyxt-ask-sequence* 0)
(defun nyxt-app-ask (console form &optional (timeout 90))
  (let ((marker (format nil "[NYXT ASK ~d COMPLETE]" (incf *nyxt-ask-sequence*))))
    (image:send console
      (format nil "(multiple-value-prog1 ~a (format t ~s) (finish-output))"
        form (format nil "~%~a~%" marker)))
    (let ((out (image:expect console (list marker "debugger invoked") :timeout timeout)))
      (when (search "debugger invoked" out) (error "Guest: ~a" out))
      (concatenate 'string out (image:expect console (format nil "~%* ") :timeout 15)))))
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
  ;; Keep the world's control dispatcher available to init's health probes.
  (loop repeat (* seconds 5)
        for out = (nyxt-app-ask console
                    (format nil "(nyxt-eval *nyxt-app* ~s :timeout 10)"
                      (format nil "(when ~a :nyxt-condition-satisfied)" predicate)) 20)
        when (search ":NYXT-CONDITION-SATISFIED" out) return t
        do (sleep .2)
        finally (error "Nyxt condition timed out: ~a" predicate)))
(defun nyxt-app-dock (console)
  ;; Read Harbor's current logical layout; exercise its real HID click path.
  (let* ((out (nyxt-app-ask console
           "(destructuring-bind (dx dy width height) (darterfly/layer:main-display-bounds)
              (declare (ignore dx dy))
              (loop repeat 50
                for layout = (darterfly/layer:dock-layout
                               (darterfly/kit::all-window-descriptions) width height)
                for dock = (find-if (lambda (w)
                  (let ((p (darterfly/bsd:pfind (darterfly/windowserver::owner w))))
                    (and p (equal \"Dock\" (darterfly/bsd::proc-comm p)))))
                  darterfly/windowserver::*windows*)
                when (and dock (equal (getf layout :frame)
                  (list (darterfly/windowserver::window-x dock)
                        (darterfly/windowserver::window-y dock)
                        (darterfly/windowserver::window-width dock)
                        (darterfly/windowserver::window-height dock))))
                return (let* ((item (find \"Nyxt\" (getf layout :items)
                                      :key (lambda (i) (getf i :key)) :test #'equal))
                              (outer (getf layout :frame)) (inner (getf item :frame)))
                         (assert item) (sleep .1)
                         (format t \"~&[NYXT DOCK POINT] ~s~%\"
                           (list (+ (first outer) (first inner) (floor (third inner) 2))
                                 (+ (second outer) (second inner) (floor (fourth inner) 2)))))
                do (sleep .1)
                finally (error \"Dock layout did not settle\")))"))
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

