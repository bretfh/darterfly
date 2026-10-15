(defpackage #:finch/image
  (:use #:cl)
  (:export #:core #:image #:boot #:check-boot #:write-cpio #:*build*
   #:console #:expect #:send #:transcript #:finish #:screendump #:pixel #:monitor #:pointer #:qmp #:send-keys
   #:boot-efi #:mach-kernel #:esp #:bare-console #:bare-boot #:send-char #:*screen-size* #:update-root #:desktop #:copy-in))
(in-package #:finch/image)

(defvar *build* (asdf:system-relative-pathname :finch "build/"))

(defun build-path (name)
  (merge-pathnames name (ensure-directories-exist *build*)))

(defun sh (&rest args)
  (uiop:run-program args :output :string :error-output :output))

(defun core ()
  (let ((path (build-path "finch")))
    (uiop:run-program
     (list "sbcl" "--noinform" "--no-userinit" "--non-interactive"
           "--eval" "(require :asdf)"
           "--eval" "(mapc #'asdf:load-system '(:finch/kernel :finch/launchd :finch/shell :finch/io :finch/text :finch/imageio :finch/windowserver :finch/apps))"
           "--eval" (format nil "(setf finch/kernel::*build-date* ~s)" (date))
           "--eval" (format nil "(sb-ext:save-lisp-and-die ~s :executable t :save-runtime-options t :toplevel (lambda () (finch/kernel:start)))"
                            (uiop:native-namestring path)))
     :output *standard-output* :error-output *error-output*)
    path))

(defun date ()
  (multiple-value-bind (s m h d mo y) (decode-universal-time (get-universal-time) 0)
    (format nil "~d-~2,'0d-~2,'0d ~2,'0d:~2,'0d:~2,'0d UTC" y mo d h m s)))

(defun libraries (executable)
  (let ((out (uiop:run-program (list (uiop:native-namestring executable) "--version")
                               :output :string :ignore-error-status t
                               :environment (list "LD_TRACE_LOADED_OBJECTS=1"))))
    (loop :for line :in (uiop:split-string out :separator '(#\Newline))
          :for slash := (position #\/ line)
          :when slash
            :collect (subseq line slash (position #\Space line :start slash)))))

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
  '(("sbin/launchd" "launchd") ("bin/launchctl" "launchctl") ("bin/sh" "sh")
    ("System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer" "WindowServer")
    ("Applications/Hello.app/Contents/MacOS/Hello" "Hello")
    ("System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal" "Terminal")
    ("System/Library/CoreServices/loginwindow.app/Contents/MacOS/loginwindow" "loginwindow")
    ("System/Library/CoreServices/Dock.app/Contents/MacOS/Dock" "Dock")
    ("System/Library/CoreServices/SystemUIServer.app/Contents/MacOS/SystemUIServer" "SystemUIServer")
    ("System/Library/CoreServices/Finder.app/Contents/MacOS/Finder" "Finder")
    ("usr/libexec/finch-gui" "finch-gui")))

(defun dict (&rest pairs)
  (let ((table (make-hash-table :test 'equal)))
    (loop :for (key value) :on pairs :by #'cddr :do (setf (gethash key table) value))
    table))

(defun job (label &rest pairs)
  (list :file (format nil "Library/LaunchDaemons/~a.plist" label)
        (text (with-output-to-string (s) (finch/plist:write-plist (apply #'dict "Label" label pairs) s)))))

(defun console-job ()
  (job "finch.console" "ProgramArguments" (vector "/bin/sh") "KeepAlive" t
       "StandardInPath" "/dev/console" "StandardOutPath" "/dev/console" "StandardErrorPath" "/dev/console"))

(defun desktop-jobs ()
  (let ((hidden (dict "HideUntilCheckIn" t))
        (on-demand (dict "AfterInitialDemand" t "SuccessfulExit" nil)))
    (list (job "finch.gui" "ProgramArguments" (vector "/usr/libexec/finch-gui") "RunAtLoad" t)
          (job "finch.windowserver"
               "ProgramArguments" (vector "/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer")
               "MachServices" (dict "com.apple.windowserver" t "com.apple.windowserver.active" hidden
                                    "com.apple.CARenderServer" hidden))
          (job "finch.loginwindow"
               "ProgramArguments" (vector "/System/Library/CoreServices/loginwindow.app/Contents/MacOS/loginwindow")
               "MachServices" (dict "com.apple.loginwindow" t))
          (job "finch.dock" "Program" "/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock" "KeepAlive" on-demand)
          (job "finch.systemuiserver" "Program" "/System/Library/CoreServices/SystemUIServer.app/Contents/MacOS/SystemUIServer"
               "KeepAlive" on-demand)
          (job "finch.finder" "Program" "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder"
               "KeepAlive" on-demand "ThrottleInterval" 1))))

(defun fonts ()
  (let ((dir (format nil "~a/share/fonts/truetype/" (uiop:getenv "GUIX_ENVIRONMENT"))))
    (loop :for file :in (directory (format nil "~aAdwaita*.ttf" dir))
          :collect (list :file (format nil "System/Library/Fonts/~a.ttf" (pathname-name file))
                         (octets file)))))

(defparameter *icons*
  '(("places" "folder") ("mimetypes" "application-x-executable") ("mimetypes" "text-x-generic")
    ("devices" "drive-harddisk")
    ("legacy" "system-file-manager-symbolic") ("legacy" "utilities-terminal-symbolic")
    ("legacy" "accessories-text-editor-symbolic")))

(defun icons ()
  (let ((theme (format nil "~a/share/icons/Adwaita/" (uiop:getenv "GUIX_ENVIRONMENT")))
        (white (build-path "symbolic.css")))
    (with-open-file (s white :direction :output :if-exists :supersede)
      (write-line "* { fill: #ffffff !important; }" s))
    (loop :for (kind name) :in *icons*
          :for symbolic := (string= kind "legacy")
          :for png := (build-path (format nil "~a.png" name))
          :do (uiop:run-program (append (list "rsvg-convert" "-w" "128" "-h" "128" "-o" (uiop:native-namestring png))
                                        (and symbolic (list "-s" (uiop:native-namestring white)))
                                        (list (format nil "~a~:[scalable~;symbolic~]/~a/~a.svg" theme symbolic kind name)))
                                :error-output *error-output*)
          :collect (list :file (format nil "usr/share/icons/Adwaita/~a/~a.png" kind name) (octets png)))))

(defun kexts ()
  (let ((dir (format nil "~a/lib/modules/" (uiop:getenv "GUIX_ENVIRONMENT"))))
    (loop :for release :in (directory (format nil "~a*/" dir))
          :for name := (car (last (pathname-directory release)))
          :append (loop :for kext :in finch/io:*kexts*
                        :collect (list :file (format nil "lib/modules/~a/~a" name kext)
                                       (octets (format nil "~a~a" (uiop:native-namestring release) kext)))))))

(defun root ()
  (append
   (kexts)
   (list (list :dir "dev")
         (list :char "dev/console" 5 1)
         (list :char "dev/null" 1 3)
         (list :dir "proc") (list :dir "sys") (list :dir "tmp")
         (list :dir "System/Library/LaunchDaemons")
         (console-job))
   (loop :for (path program) :in *programs*
         :collect (list :file path (text (format nil "#!finch ~a~%" program)) #o100755))
   (desktop-jobs)
   (fonts)
   (icons)))

(defun image ()
  (let* ((core (core))
         (libraries (libraries core)))
    (write-cpio (build-path "finch.cpio")
                (append
                 (list (list :file "init" (octets core) #o100755))
                 (root)
                 (loop :for library :in libraries
                       :collect (list :file (subseq library 1) (octets library) #o100755))))))

(defun kernel ()
  (format nil "~a/bzImage" (uiop:getenv "GUIX_ENVIRONMENT")))

(defun monitor-path ()
  (uiop:native-namestring (build-path "monitor.sock")))

(defun qmp-path ()
  (uiop:native-namestring (build-path "qmp.sock")))

(defun qmp (command &optional arguments)
  (finch/qmp:qmp (qmp-path) command arguments))

(defun key-name (char)
  (case char
    (#\( "9") (#\) "0") (#\+ "equal") (#\* "8") (#\" "apostrophe") (#\Space "spc")
    (#\Newline "ret") (#\- "minus") (#\= "equal") (#\. "dot") (#\/ "slash")
    (#\: "semicolon") (#\; "semicolon") (#\' "apostrophe") (#\, "comma") (#\< "comma") (#\> "dot")
    (#\[ "bracket_left") (#\] "bracket_right") (#\{ "bracket_left") (#\} "bracket_right")
    (#\\ "backslash") (#\| "backslash") (#\` "grave_accent") (#\~ "grave_accent")
    (#\_ "minus") (#\? "slash") (#\! "1") (#\@ "2") (#\# "3") (#\$ "4") (#\% "5") (#\^ "6") (#\& "7")
    (t (string (char-downcase char)))))

(defun send-keys (string)
  (flet ((key (name down)
           (finch/qmp:dict "type" "key"
                           "data" (finch/qmp:dict "down" down
                                                  "key" (finch/qmp:dict "type" "qcode" "data" name)))))
    (loop :for char :across string
          :do (let* ((shift (or (find char "()+*\"!@#$%^&_{}|:<>?~") (upper-case-p char)))
                     (name (key-name char)))
                (qmp "input-send-event"
                     (finch/qmp:dict "events"
                                     (coerce (append (and shift (list (key "shift" t)))
                                                     (list (key name t) (key name nil))
                                                     (and shift (list (key "shift" nil))))
                                             'vector)))))))

(defvar *screen-size* '(1024 768))

(defun pointer (x y &optional (button nil button-p))
  (flet ((abs-event (axis value)
           (finch/qmp:dict "type" "abs" "data" (finch/qmp:dict "axis" axis "value" value))))
    (qmp "input-send-event"
         (finch/qmp:dict "events"
                         (concatenate 'vector
                                      (vector (abs-event "x" (floor (* x 32768) (first *screen-size*)))
                                              (abs-event "y" (floor (* y 32768) (second *screen-size*))))
                                      (and button-p
                                           (vector (finch/qmp:dict "type" "btn"
                                                                   "data" (finch/qmp:dict "button" "left"
                                                                                          "down" button)))))))))

(defun qemu (&rest args)
  (append (list "qemu-system-x86_64" "-enable-kvm" "-cpu" "host" "-m" "4096" "-smp" "4"
                "-machine" "pc,vmport=off"
                "-monitor" (format nil "unix:~a,server=on,wait=off" (monitor-path))
                "-qmp" (format nil "unix:~a,server=on,wait=off" (qmp-path))
                "-device" "virtio-tablet-pci"
                "-device" "virtio-keyboard-pci"
                "-kernel" (kernel)
                "-initrd" (uiop:native-namestring (build-path "finch.cpio"))
                "-no-reboot")
          args))

(defun boot (&optional (boot-args "vga=0x318"))
  (uiop:run-program (qemu "-serial" "mon:stdio" "-append" (format nil "console=ttyS0 quiet ~a" boot-args))
                    :input :interactive :output :interactive :error-output :interactive))

(defun check-boot (&key (boot-args "halt") input)
  (uiop:run-program (qemu "-display" "none" "-serial" "stdio"
                          "-append" (format nil "console=ttyS0 quiet ~a" boot-args))
                    :input (and input (make-string-input-stream input))
                    :output :string :error-output :output))

(defstruct (console (:constructor %console (process))) process (seen (make-string-output-stream)) (text ""))

(defun console (&key (boot-args "vga=0x318") args)
  (%console (uiop:launch-program (or args
                                     (qemu "-display" "none" "-serial" "stdio"
                                           "-append" (format nil "console=ttyS0 quiet ~a" boot-args)))
                                 :input :stream :output :stream :error-output :output)))

(defun cpu-states ()
  (ignore-errors
   (let ((r (qmp "human-monitor-command" (finch/qmp:dict "command-line" "info registers -a"))))
     (when (stringp r)
       (with-output-to-string (out)
         (with-input-from-string (s r)
           (loop for line = (read-line s nil) while line
                 when (or (search "CPU#" line) (search "RIP=" line) (search "RSP=" line) (search "RAX=" line))
                   do (write-line line out))))))))

(defun expect (console text &key (timeout 30))
  (let* ((out (uiop:process-info-output (console-process console)))
         (deadline (+ (get-internal-real-time) (* timeout internal-time-units-per-second))))
    (loop
      (let ((at (search text (console-text console))))
        (when at
          (let ((seen (subseq (console-text console) 0 (+ at (length text)))))
            (setf (console-text console) (subseq (console-text console) (+ at (length text))))
            (return seen))))
      (when (> (get-internal-real-time) deadline)
        (error "console: no ~s after ~a s, saw ~s~@[~%cpus:~%~a~]" text timeout (console-text console) (cpu-states)))
      (if (listen out)
          (let ((c (read-char out nil)))
            (unless c (error "console: closed, saw ~s" (console-text console)))
            (unless (char= c #\Return)
              (write-char c (console-seen console))
              (setf (console-text console)
                    (concatenate 'string (console-text console) (string c)))))
          (if (uiop:process-alive-p (console-process console))
              (sleep 0.01)
              (error "console: finch stopped, saw ~s" (console-text console)))))))

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
    (qmp "screendump" (finch/qmp:dict "filename" path))
    (read-ppm path)))

(defun pixel (screen x y)
  (aref screen y x))
