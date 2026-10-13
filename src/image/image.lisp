(defpackage #:finch/image
  (:use #:cl)
  (:export #:core #:image #:boot #:check-boot #:write-cpio #:*build*
   #:console #:expect #:send #:transcript #:finish))
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
           "--eval" "(asdf:load-system :finch/kernel)"
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

(defun image ()
  (let* ((core (core))
         (libraries (libraries core)))
    (write-cpio (build-path "finch.cpio")
                (append
                 (list (list :file "init" (octets core) #o100755)
                       (list :dir "dev")
                       (list :char "dev/console" 5 1)
                       (list :char "dev/null" 1 3)
                       (list :dir "proc") (list :dir "sys") (list :dir "tmp"))
                 (loop :for library :in libraries
                       :collect (list :file (subseq library 1) (octets library) #o100755))))))

(defun kernel ()
  (format nil "~a/bzImage" (uiop:getenv "GUIX_ENVIRONMENT")))

(defun qemu (&rest args)
  (append (list "qemu-system-x86_64" "-enable-kvm" "-cpu" "host" "-m" "4096" "-smp" "4"
                "-kernel" (kernel)
                "-initrd" (uiop:native-namestring (build-path "finch.cpio"))
                "-no-reboot")
          args))

(defun boot (&optional (boot-args ""))
  (uiop:run-program (qemu "-nographic" "-append" (format nil "console=ttyS0 quiet ~a" boot-args))
                    :input :interactive :output :interactive :error-output :interactive))

(defun check-boot (&key (boot-args "halt") input)
  (uiop:run-program (qemu "-display" "none" "-serial" "stdio"
                          "-append" (format nil "console=ttyS0 quiet ~a" boot-args))
                    :input (and input (make-string-input-stream input))
                    :output :string :error-output :output))

(defstruct (console (:constructor %console (process))) process (seen (make-string-output-stream)) (text ""))

(defun console (&key (boot-args ""))
  (%console (uiop:launch-program (qemu "-display" "none" "-serial" "stdio"
                                       "-append" (format nil "console=ttyS0 quiet ~a" boot-args))
                                 :input :stream :output :stream :error-output :output)))

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
        (error "console: no ~s after ~a s, saw ~s" text timeout (console-text console)))
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

(defun transcript (console)
  (get-output-stream-string (console-seen console)))

(defun finish (console)
  (let ((process (console-process console)))
    (unwind-protect (uiop:wait-process process)
      (when (uiop:process-alive-p process) (uiop:terminate-process process :urgent t)))))
