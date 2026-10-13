(in-package #:finch/tahoe)

(defun qmp-socket () (merge-pathnames "qmp.sock" *home*))

(defun qmp (command &optional arguments)
  (finch/qmp:qmp (qmp-socket) command arguments))

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

(defparameter *screen* '(2560 1600))

(defun axis (name value limit)
  (dict "type" "abs" "data" (dict "axis" name "value" (floor (* value 32767) (1- limit)))))

(defun button (down)
  (vector (dict "type" "btn" "data" (dict "down" down "button" "left"))))

(defun click (x y)
  (destructuring-bind (w h) *screen*
    (qmp "input-send-event" (dict "events" (vector (axis "x" x w) (axis "y" y h))))
    (sleep 0.1)
    (qmp "input-send-event" (dict "events" (button t)))
    (sleep 0.08)
    (qmp "input-send-event" (dict "events" (button nil)))))
