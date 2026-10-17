(defpackage #:darterfly/image
  (:use #:cl)
  (:export #:write-cpio #:*build*
   #:console #:expect #:send #:transcript #:finish #:screendump #:pixel #:monitor #:pointer #:qmp #:send-keys
   #:boot-efi #:kernel-file #:esp #:bare-console #:bare-boot #:send-char #:*screen-size* #:update-root #:desktop #:copy-in #:build-sbcl #:*c-compiler* #:build-tcc #:*input-devices* #:*network-device* #:usb-image #:deploy))
(in-package #:darterfly/image)

(defvar *build* (asdf:system-relative-pathname :darterfly "build/"))

(defun build-path (name)
  (merge-pathnames name (ensure-directories-exist *build*)))

(defun octets (path)
  (with-open-file (s path :element-type '(unsigned-byte 8))
    (let ((v (make-array (file-length s) :element-type '(unsigned-byte 8))))
      (read-sequence v s)
      v)))

(defun parents (path)
  (loop :for i := (position #\/ path :start 1) :then (position #\/ path :start (1+ i))
        :while i
        :collect (subseq path 1 i)))

(defun put-header (s ino mode size namesize &key (rdev-major 0) (rdev-minor 0) (nlink 1))
  (write-sequence (map '(vector (unsigned-byte 8)) #'char-code
                       (format nil "070701~{~8,'0x~}"
                               (list ino mode 0 0 nlink 0 size 0 0 rdev-major rdev-minor namesize 0)))
                  s))

(defun pad (s n)
  (dotimes (i (mod (- n) 4)) (write-byte 0 s)))

(defun put-entry (s ino name mode &key (data #()) (rdev-major 0) (rdev-minor 0))
  (let ((namesize (1+ (length name))))
    (put-header s ino mode (length data) namesize :rdev-major rdev-major :rdev-minor rdev-minor
                                                   :nlink (if (= (logand mode #o170000) #o040000) 2 1))
    (write-sequence (map '(vector (unsigned-byte 8)) #'char-code name) s)
    (write-byte 0 s)
    (pad s (+ 110 namesize))
    (write-sequence data s)
    (pad s (length data))))

(defun write-cpio (path entries)
  (with-open-file (s path :direction :output :if-exists :supersede :element-type '(unsigned-byte 8))
    (let ((ino 0)
          (dirs (make-hash-table :test 'equal)))
      (flet ((dir (name)
               (unless (gethash name dirs)
                 (setf (gethash name dirs) t)
                 (put-entry s (incf ino) name #o040755))))
        (loop :for (kind name . more) :in entries
              :do (mapc #'dir (parents (format nil "/~a" name)))
                  (ecase kind
                    (:dir (dir name))
                    (:file (destructuring-bind (data &optional (mode #o100644)) more
                             (put-entry s (incf ino) name mode :data data)))
                    (:char (destructuring-bind (major minor) more
                             (put-entry s (incf ino) name #o020600 :rdev-major major :rdev-minor minor)))))
        (put-entry s (incf ino) "TRAILER!!!" 0)))
    path))

(defun text (string)
  (map '(vector (unsigned-byte 8)) #'char-code string))

(defparameter *programs*
  '(("sbin/init" "init") ("bin/service" "service") ("bin/sh" "sh")
    ("System/Library/Services/WindowServer" "WindowServer")
    ("Applications/Hello.app/Contents/Programs/Hello" "Hello")
    ("System/Applications/Listener.app/Contents/Programs/Listener" "Listener")
    ("System/Applications/Utilities/Force Quit.app/Contents/Programs/Force Quit" "Force Quit")
    ("System/Applications/Editor.app/Contents/Programs/Editor" "Editor")
    ("System/Applications/Generations.app/Contents/Programs/Generations" "Generations")
    ("System/Applications/Fetch.app/Contents/Programs/Fetch" "Fetch")
    ("System/Applications/Install.app/Contents/Programs/Install" "Install")
    ("System/Applications/Utilities/Terminal.app/Contents/Programs/Terminal" "Terminal")
    ("System/Library/Services/Session.app/Contents/Programs/Session" "Session")
    ("System/Library/Services/Dock.app/Contents/Programs/Dock" "Dock")
    ("System/Library/Services/MenuBar.app/Contents/Programs/MenuBar" "MenuBar")
    ("System/Library/Services/Files.app/Contents/Programs/Files" "Files")
    ("usr/libexec/darterfly-gui" "darterfly-gui")))

(defun job (label &rest keys)
  (list :file (format nil "Library/Jobs/~a.job" label)
        (text (with-standard-io-syntax
                (let ((*print-case* :downcase)) (prin1-to-string (list* :label label keys)))))))

(defun desktop-jobs ()
  (list (job "darterfly.gui" :arguments '("/usr/libexec/darterfly-gui") :run-at-load t)
        (job "darterfly.windowserver" :program "/System/Library/Services/WindowServer"
             :services '("windowserver" ("windowserver.active" :hidden t) ("renderserver" :hidden t)))
        (job "darterfly.session" :program "/System/Library/Services/Session.app/Contents/Programs/Session"
             :services '("Session"))
        (job "darterfly.dock" :program "/System/Library/Services/Dock.app/Contents/Programs/Dock" :keep-alive :after-demand)
        (job "darterfly.menubar" :program "/System/Library/Services/MenuBar.app/Contents/Programs/MenuBar"
             :keep-alive :after-demand)
        (job "darterfly.files" :program "/System/Library/Services/Files.app/Contents/Programs/Files"
             :keep-alive :after-demand :throttle 1)))

(defun fonts ()
  (let ((dir (format nil "~a/share/fonts/truetype/" (uiop:getenv "GUIX_ENVIRONMENT"))))
    (loop :for file :in (directory (format nil "~aAdwaita*.ttf" dir))
          :collect (list :file (format nil "System/Library/Fonts/~a.ttf" (pathname-name file))
                         (octets file)))))

(defparameter *icons*
  '(("places" "folder") ("mimetypes" "application-x-executable") ("mimetypes" "text-x-generic")
    ("devices" "drive-harddisk")
    ("legacy" "system-file-manager-symbolic") ("legacy" "utilities-terminal-symbolic")
    ("legacy" "accessories-text-editor-symbolic") ("actions" "system-run-symbolic")
    ("status" "software-update-available-symbolic")))

(defun icons ()
  (let ((theme (format nil "~a/share/icons/Adwaita/" (uiop:getenv "GUIX_ENVIRONMENT")))
        (white (build-path "symbolic.css")))
    (with-open-file (s white :direction :output :if-exists :supersede)
      (write-line "* { fill: #ffffff !important; }" s))
    (loop :for (kind name) :in *icons*
          :for symbolic := (uiop:string-suffix-p name "-symbolic")
          :for png := (build-path (format nil "~a.png" name))
          :do (uiop:run-program (append (list "rsvg-convert" "-w" "128" "-h" "128" "-o" (uiop:native-namestring png))
                                        (and symbolic (list "-s" (uiop:native-namestring white)))
                                        (list (format nil "~a~:[scalable~;symbolic~]/~a/~a.svg" theme symbolic kind name)))
                                :error-output *error-output*)
          :collect (list :file (format nil "usr/share/icons/Adwaita/~a/~a.png" kind name) (octets png)))))

(defun monitor-path ()
  (uiop:native-namestring (build-path "monitor.sock")))

(defun qmp-path ()
  (uiop:native-namestring (build-path "qmp.sock")))

(defun qmp (command &optional arguments)
  (darterfly/qmp:qmp (qmp-path) command arguments))

(defun key-name (char)
  (case char
    (#\( "9") (#\) "0") (#\+ "equal") (#\* "8") (#\" "apostrophe") (#\Space "spc")
    (#\Newline "ret") (#\- "minus") (#\= "equal") (#\. "dot") (#\/ "slash")
    (#\: "semicolon") (#\; "semicolon") (#\' "apostrophe") (#\, "comma") (#\< "comma") (#\> "dot")
    (#\[ "bracket_left") (#\] "bracket_right") (#\{ "bracket_left") (#\} "bracket_right")
    (#\\ "backslash") (#\| "backslash") (#\` "grave_accent") (#\~ "grave_accent")
    (#\_ "minus") (#\? "slash") (#\! "1") (#\@ "2") (#\# "3") (#\$ "4") (#\% "5") (#\^ "6") (#\& "7")
    (#.(code-char #xF700) "up") (#.(code-char #xF701) "down") (#.(code-char #xF702) "left") (#.(code-char #xF703) "right")
    (t (if (control-char-p char)
           (string (code-char (+ 96 (char-code char))))
           (string (char-downcase char))))))

(defun control-char-p (char)
  (and (<= 1 (char-code char) 26) (not (member char '(#\Backspace #\Tab #\Newline #\Return)))))

(defun send-keys (string)
  (flet ((key (name down)
           (darterfly/qmp:dict "type" "key"
                           "data" (darterfly/qmp:dict "down" down
                                                  "key" (darterfly/qmp:dict "type" "qcode" "data" name)))))
    (loop :for char :across string
          :do (let* ((shift (or (find char "()+*\"!@#$%^&_{}|:<>?~") (upper-case-p char)))
                     (held (cond (shift "shift") ((control-char-p char) "ctrl")))
                     (name (key-name char)))
                (qmp "input-send-event"
                     (darterfly/qmp:dict "events"
                                     (coerce (append (and held (list (key held t)))
                                                     (list (key name t) (key name nil))
                                                     (and held (list (key held nil))))
                                             'vector)))))))

(defvar *screen-size* '(1280 800))

(defun pointer (x y &optional (button nil button-p))
  (flet ((abs-event (axis value)
           (darterfly/qmp:dict "type" "abs" "data" (darterfly/qmp:dict "axis" axis "value" value))))
    (qmp "input-send-event"
         (darterfly/qmp:dict "events"
                         (concatenate 'vector
                                      (vector (abs-event "x" (floor (* x 32768) (first *screen-size*)))
                                              (abs-event "y" (floor (* y 32768) (second *screen-size*))))
                                      (and button-p
                                           (vector (darterfly/qmp:dict "type" "btn"
                                                                   "data" (darterfly/qmp:dict "button" "left"
                                                                                          "down" button)))))))))

(defstruct (console (:constructor %console (process))) process (seen (make-string-output-stream)) (text (pending-text)))

(defun console (&key args)
  (%console (uiop:launch-program args :input :stream :output :stream :error-output :output)))

(defun cpu-states ()
  (ignore-errors
   (let ((r (qmp "human-monitor-command" (darterfly/qmp:dict "command-line" "info registers -a"))))
     (when (stringp r)
       (with-output-to-string (out)
         (with-input-from-string (s r)
           (loop for line = (read-line s nil) while line
                 when (or (search "CPU#" line) (search "RIP=" line) (search "RSP=" line) (search "RAX=" line))
                   do (write-line line out))))))))

(defun first-match (texts string &optional (start 0))
  (let ((best nil) (found nil))
    (dolist (text (if (listp texts) texts (list texts)) (values best found))
      (let ((at (search text string :start2 start)))
        (when (and at (or (null best) (< at best)))
          (setf best at found text))))))

(defun pending-text (&optional (initial ""))
  (make-array (length initial) :element-type 'character :adjustable t :fill-pointer t :initial-contents initial))

(defun expect (console text &key (timeout 30))
  (let* ((out (uiop:process-info-output (console-process console)))
         (deadline (+ (get-internal-real-time) (* timeout internal-time-units-per-second)))
         (longest (reduce #'max (if (listp text) text (list text)) :key #'length))
         (searched 0))
    (loop
      (let ((pending (console-text console)))
        (multiple-value-bind (at found) (first-match text pending (max 0 (- searched longest -1)))
          (when at
            (let ((end (+ at (length found))))
              (setf (console-text console) (pending-text (subseq pending end)))
              (return (values (subseq pending 0 end) found))))
          (setf searched (length pending))))
      (when (> (get-internal-real-time) deadline)
        (error "console: no ~s after ~a s, saw ~s~@[~%cpus:~%~a~]" text timeout (console-text console) (cpu-states)))
      (if (listen out)
          (loop :while (listen out)
                :repeat 65536
                :do (let ((c (read-char out nil)))
                      (unless c (error "console: closed, saw ~s" (console-text console)))
                      (unless (char= c #\Return)
                        (write-char c (console-seen console))
                        (vector-push-extend c (console-text console)))))
          (if (uiop:process-alive-p (console-process console))
              (sleep 0.01)
              (error "console: darterfly stopped, saw ~s" (console-text console)))))))

(defun send (console line)
  (let ((in (uiop:process-info-input (console-process console))))
    (write-line line in)
    (finish-output in)))

(defun send-char (console char)
  (let ((in (uiop:process-info-input (console-process console))))
    (write-char char in)
    (finish-output in)))

(defun transcript (console)
  (get-output-stream-string (console-seen console)))

(defun finish (console &optional (seconds 5))
  (let ((process (console-process console)))
    (loop :repeat (* seconds 20)
          :while (uiop:process-alive-p process)
          :do (sleep 0.05))
    (when (uiop:process-alive-p process)
      (uiop:terminate-process process :urgent t))
    (uiop:wait-process process)))

(defun monitor (command)
  (let ((socket (make-instance 'sb-bsd-sockets:local-socket :type :stream)))
    (sb-bsd-sockets:socket-connect socket (monitor-path))
    (let ((stream (sb-bsd-sockets:socket-make-stream socket :input t :output t :external-format :latin-1)))
      (unwind-protect
           (progn
             (format stream "~a~%" command)
             (finish-output stream)
             (sleep 1)
             (loop :while (listen stream) :do (read-char stream)))
        (close stream)))))

(defun read-ppm (path)
  (with-open-file (s path :element-type '(unsigned-byte 8))
    (flet ((token ()
             (let ((chars (loop :for b := (read-byte s)
                                :until (member b '(32 10 13 9))
                                :collect (code-char b))))
               (coerce chars 'string))))
      (token)
      (let* ((width (parse-integer (token)))
             (height (parse-integer (token)))
             (pixels (make-array (list height width) :element-type '(unsigned-byte 32))))
        (token)
        (let ((raw (make-array (* width height 3) :element-type '(unsigned-byte 8))))
          (read-sequence raw s)
          (dotimes (y height)
            (dotimes (x width)
              (let ((at (* 3 (+ x (* y width)))))
                (setf (aref pixels y x)
                      (logior #xff000000 (ash (aref raw at) 16) (ash (aref raw (+ at 1)) 8) (aref raw (+ at 2))))))))
        pixels))))

(defun screendump ()
  (let ((path (uiop:native-namestring (build-path "screen.ppm"))))
    (uiop:delete-file-if-exists path)
    (qmp "screendump" (darterfly/qmp:dict "filename" path))
    (read-ppm path)))

(defun pixel (screen x y)
  (aref screen y x))
