(in-package #:finch/apps)

(defparameter +terminal-font+ "SFNSMono")
(defparameter +terminal-size+ 13)
(defparameter +line-height+ 17)

(defclass terminal-view (kit:view)
  ((output :initform "" :accessor output)
   (input :initform "" :accessor input)
   (to-shell :initarg :to-shell :reader to-shell)))

(defun visible-lines (view rows)
  (last (uiop:split-string (concatenate 'string (output view) (input view)) :separator '(#\Newline))
        rows))

(defmethod kit:draw ((view terminal-view) bitmap)
  (text:fill-bitmap bitmap 1.0 1.0 1.0 1.0)
  (let* ((rows (floor (- (kit:view-height view) 8) +line-height+))
         (font (text:font +terminal-font+ +terminal-size+))
         (lines (visible-lines view rows)))
    (loop :for line :in lines
          :for y :from (+ 4 +line-height+) :by +line-height+
          :do (text:draw-string bitmap font line 6 (- y 4) 0.0 0.0 0.0))
    (with-open-file (s "/tmp/Terminal.txt" :direction :output :if-exists :supersede :if-does-not-exist :create)
      (format s "~{~a~%~}" lines))))

(defmethod kit:key-down ((view terminal-view) characters keycode)
  (declare (ignore keycode))
  (let ((char (char characters 0)))
    (case char
      (#\Return
       (let ((line (format nil "~a~%" (input view))))
         (setf (output view) (concatenate 'string (output view) line)
               (input view) "")
         (bsd:write (to-shell view) (sb-ext:string-to-octets line :external-format :utf-8))))
      (#\Backspace
       (when (plusp (length (input view)))
         (setf (input view) (subseq (input view) 0 (1- (length (input view)))))))
      (t (setf (input view) (concatenate 'string (input view) characters))))
    (kit:needs-display view)
    t))

(defun shell-output (view from-shell)
  (lambda ()
    (loop
      (let ((octets (handler-case (bsd:read from-shell 4096) (bsd:errno () #()))))
        (when (zerop (length octets)) (return))
        (let ((text (sb-ext:octets-to-string octets :external-format :utf-8)))
          (kit:perform-on-main (lambda ()
                                 (setf (output view) (concatenate 'string (output view) text))
                                 (kit:needs-display view))))))))

(bsd:define-program "Terminal" (argv envp)
  (multiple-value-bind (shell-in to-shell) (bsd:pipe)
    (multiple-value-bind (from-shell shell-out) (bsd:pipe)
      (bsd:posix-spawn "/bin/sh" (list "/bin/sh") nil
                       :file-actions (list (list :dup2 shell-in 0) (list :dup2 shell-out 1)
                                           (list :dup2 shell-out 2)
                                           (list :close shell-in) (list :close shell-out)
                                           (list :close to-shell) (list :close from-shell)))
      (bsd:close shell-in)
      (bsd:close shell-out)
      (let* ((window (kit:make-window :title "Terminal — sh" :x 160 :y 100 :width 700 :height 460))
             (view (make-instance 'terminal-view :to-shell to-shell :frame (vector 0 0 676 408))))
        (kit:add-subview (kit:content-view window) view)
        (setf (kit:first-responder window) view)
        (kit:show window)
        (bsd:bsdthread-create (shell-output view from-shell) "shell output")
        (kit:run)))))
