(in-package #:finch/tahoe)

(defun qmp-socket () (merge-pathnames "qmp.sock" *home*))

(defun qmp-line (stream)
  (com.inuoe.jzon:parse (read-line stream)))

(defun qmp-execute (stream command arguments)
  (write-string (com.inuoe.jzon:stringify
                 (if arguments
                     (dict "execute" command "arguments" arguments)
                     (dict "execute" command)))
                stream)
  (terpri stream)
  (finish-output stream)
  (loop :for reply := (qmp-line stream)
        :do (multiple-value-bind (v found) (gethash "return" reply)
              (when found (return v)))
            (let ((e (gethash "error" reply)))
              (when e (error "QMP ~a: ~a" command (gethash "desc" e))))))

(defun qmp (command &optional arguments)
  (let ((socket (make-instance 'sb-bsd-sockets:local-socket :type :stream)))
    (unwind-protect
         (progn
           (sb-bsd-sockets:socket-connect socket (uiop:native-namestring (qmp-socket)))
           (let ((s (sb-bsd-sockets:socket-make-stream socket :input t :output t
                                                               :external-format :utf-8
                                                               :buffering :full)))
             (qmp-line s)
             (qmp-execute s "qmp_capabilities" nil)
             (qmp-execute s command arguments)))
      (sb-bsd-sockets:socket-close socket))))

(defun query-status ()
  (let ((r (qmp "query-status")))
    (values (intern (string-upcase (gethash "status" r)) :keyword) (gethash "running" r))))

(defun next-shot ()
  (let ((dir (merge-pathnames "shots/" *home*)))
    (merge-pathnames (format nil "~3,'0d.png" (length (directory (merge-pathnames "*.png" dir)))) dir)))

(defun screendump (&optional (path (next-shot)))
  (let ((path (merge-pathnames path)))
    (ensure-directories-exist path)
    (qmp "screendump" (dict "filename" (uiop:native-namestring path) "format" "png"))
    path))

(defun qcode (combo)
  (map 'vector (lambda (k) (dict "type" "qcode" "data" k))
       (uiop:split-string combo :separator "-")))

(defun send-key (&rest combos)
  (dolist (combo combos)
    (qmp "send-key" (dict "keys" (qcode combo)))
    (sleep 0.1)))

(defparameter +qcodes+
  '((#\Space . "spc") (#\Newline . "ret") (#\Tab . "tab") (#\- . "minus") (#\= . "equal")
    (#\. . "dot") (#\, . "comma") (#\/ . "slash") (#\\ . "backslash") (#\; . "semicolon")
    (#\' . "apostrophe") (#\` . "grave_accent") (#\[ . "bracket_left") (#\] . "bracket_right")
    (#\_ . "shift-minus") (#\+ . "shift-equal") (#\> . "shift-dot") (#\< . "shift-comma")
    (#\? . "shift-slash") (#\| . "shift-backslash") (#\: . "shift-semicolon")
    (#\" . "shift-apostrophe") (#\~ . "shift-grave_accent") (#\{ . "shift-bracket_left")
    (#\} . "shift-bracket_right") (#\! . "shift-1") (#\@ . "shift-2") (#\# . "shift-3")
    (#\$ . "shift-4") (#\% . "shift-5") (#\^ . "shift-6") (#\& . "shift-7") (#\* . "shift-8")
    (#\( . "shift-9") (#\) . "shift-0")))

(defun send-text (text)
  (loop :for c :across text
        :for named := (cdr (assoc c +qcodes+))
        :do (qmp "send-key" (dict "keys" (qcode (cond (named)
                                                      ((upper-case-p c)
                                                       (format nil "shift-~a" (char-downcase c)))
                                                      (t (string c))))))
            (sleep 0.03)))

(defun system-powerdown () (qmp "system_powerdown"))
(defun quit () (qmp "quit"))
