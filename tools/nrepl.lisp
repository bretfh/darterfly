(require :sb-bsd-sockets)

(defpackage #:darterfly/tools/nrepl
  (:use #:cl))
(in-package #:darterfly/tools/nrepl)

(defconstant +i+ (char-code #\i))
(defconstant +l+ (char-code #\l))
(defconstant +d+ (char-code #\d))
(defconstant +e+ (char-code #\e))
(defconstant +colon+ (char-code #\:))
(defconstant +minus+ (char-code #\-))
(defconstant +zero+ (char-code #\0))
(defconstant +nine+ (char-code #\9))

(defstruct (rdr (:constructor %rdr (stream))) stream peeked)

(defun %peek (r) (or (rdr-peeked r) (setf (rdr-peeked r) (read-byte (rdr-stream r)))))
(defun %take (r) (let ((b (%peek r))) (setf (rdr-peeked r) nil) b))

(defun %decode-int (r)
  (let ((neg nil) (n 0))
    (loop (let ((b (%take r)))
            (cond ((= b +e+) (return (if neg (- n) n)))
                  ((= b +minus+) (setf neg t))
                  (t (setf n (+ (* n 10) (- b +zero+)))))))))

(defun %decode-string-body (r b0)
  (let ((n (- b0 +zero+)))
    (loop (let ((b (%take r)))
            (when (= b +colon+) (return))
            (setf n (+ (* n 10) (- b +zero+)))))
    (let ((body (make-array n :element-type '(unsigned-byte 8))))
      (unless (= n (read-sequence body (rdr-stream r)))
        (error 'end-of-file :stream (rdr-stream r)))
      (sb-ext:octets-to-string body :external-format :utf-8))))

(defun %decode-list (r)
  (let ((acc '()))
    (loop (if (= (%peek r) +e+)
              (progn (%take r) (return (nreverse acc)))
              (push (%decode r) acc)))))

(defun %decode-dict (r)
  (let ((acc '()))
    (loop (if (= (%peek r) +e+)
              (progn (%take r) (return (nreverse acc)))
              (let* ((k (%decode r)) (v (%decode r)))
                (push (cons k v) acc))))))

(defun %decode (r)
  (let ((b (%take r)))
    (cond ((= b +i+) (%decode-int r))
          ((= b +l+) (%decode-list r))
          ((= b +d+) (%decode-dict r))
          ((<= +zero+ b +nine+) (%decode-string-body r b))
          (t (error "bencode: bad tag byte ~d" b)))))

(defun read-message (stream) (%decode (%rdr stream)))

(defun %write-int (stream n)
  (write-sequence (sb-ext:string-to-octets (format nil "i~de" n) :external-format :latin-1) stream))

(defun %write-str (stream s)
  (let ((oct (sb-ext:string-to-octets s :external-format :utf-8)))
    (write-sequence (sb-ext:string-to-octets (format nil "~d:" (length oct)) :external-format :latin-1) stream)
    (write-sequence oct stream)))

(defun %write-value (stream v)
  (cond ((integerp v) (%write-int stream v))
        ((stringp v) (%write-str stream v))
        ((hash-table-p v)
         (write-byte +d+ stream)
         (maphash (lambda (k val) (%write-str stream k) (%write-value stream val)) v)
         (write-byte +e+ stream))
        ((listp v)
         (write-byte +l+ stream)
         (dolist (x v) (%write-value stream x))
         (write-byte +e+ stream))
        (t (error "bencode: cannot encode ~s" v))))

(defun %msg (&rest kvs)
  (let ((h (make-hash-table :test 'equal)))
    (loop :for (k v) :on kvs :by #'cddr :do (setf (gethash k h) v))
    h))

(defvar *key* nil)

(defun send (stream msg)
  (setf (gethash "key" msg) *key*)
  (%write-value stream msg)
  (finish-output stream))

(defun %get (alist key &optional default)
  (let ((c (assoc key alist :test #'equal)))
    (if c (cdr c) default)))

(defvar *host* "127.0.0.1")

(defun connect (port)
  (handler-case
      (let ((sock (make-instance 'sb-bsd-sockets:inet-socket :type :stream :protocol :tcp)))
        (sb-bsd-sockets:socket-connect sock (sb-bsd-sockets:host-ent-address (sb-bsd-sockets:get-host-by-name *host*)) port)
        (sb-bsd-sockets:socket-make-stream
         sock :input t :output t :element-type '(unsigned-byte 8)))
    (error (c)
      (format *error-output*
              "~&nrepl: can't reach ~a:~d (~a) -- is (darterfly/nrepl:start) running?~%"
              *host* port c)
      (sb-ext:exit :code 2))))

(defun cache-dir ()
  (ensure-directories-exist
   (merge-pathnames ".cache/darterfly-nrepl/" (user-homedir-pathname))))

(defun cache-path (port)
  (merge-pathnames (format nil "~a-~d.session" *host* port) (cache-dir)))

(defun cached-session (port)
  (let ((p (cache-path port)))
    (and (probe-file p)
         (with-open-file (in p)
           (read-line in nil nil)))))

(defun save-session (port id)
  (with-open-file (out (cache-path port) :direction :output
                                          :if-exists :supersede
                                          :if-does-not-exist :create)
    (write-line id out)))

(defun clone-session (stream from)
  (send stream (%msg "op" "clone" "session" from))
  (let ((r (read-message stream)))
    (%get r "new-session")))

(defun ensure-session (stream port force-new)
  (let ((cached (and (not force-new) (cached-session port))))
    (or cached
        (let ((id (clone-session stream nil)))
          (save-session port id)
          id))))

(defun drain-eval (stream)
  (loop
    (let ((m (read-message stream)))
      (let ((out (%get m "out")) (err (%get m "err"))
            (value (%get m "value")) (ns (%get m "ns"))
            (status (%get m "status")))
        (when out (write-string out) (finish-output))
        (when err (write-string err *error-output*) (finish-output *error-output*))
        (when value
          (format t "~&=> ~a~@[ (in ~a)~]~%" value ns)
          (finish-output))
        (when status (return status))))))

(defun read-code (positional)
  (or positional
      (with-output-to-string (s)
        (loop :for line := (read-line *standard-input* nil nil)
              :while line
              :do (write-line line s)))))

(defun exit-for-status (status)
  (sb-ext:exit :code (if (member (first status) '("eval-error" "interrupted") :test #'equal) 1 0)))

(defun cmd-eval (port force-new positional)
  (let* ((stream (connect port))
         (session (ensure-session stream port force-new))
         (code (read-code positional)))
    (send stream (%msg "op" "eval" "session" session "code" code))
    (exit-for-status (drain-eval stream))))

(defun cmd-interrupt (port)
  (let* ((stream (connect port))
         (session (cached-session port)))
    (unless session
      (format *error-output* "~&nrepl: no cached session for port ~d -- nothing to interrupt~%" port)
      (sb-ext:exit :code 2))
    (send stream (%msg "op" "interrupt" "session" session))
    (let ((r (read-message stream)))
      (format t "~&~{~a~^ ~}~%" (%get r "status"))
      (sb-ext:exit :code 0))))

(defun main ()
  (let* ((argv (rest sb-ext:*posix-argv*))
         (cmd (pop argv))
         (port 4011) (force-new nil) (positional nil))
    (loop :while argv
          :do (let ((a (pop argv)))
                (cond ((string= a "--port") (setf port (parse-integer (pop argv))))
                      ((string= a "--host") (setf *host* (pop argv)))
                      ((string= a "--key") (setf *key* (pop argv)))
                      ((string= a "--new") (setf force-new t))
                      (t (setf positional a)))))
    (unless *key*
      (let ((file (merge-pathnames "../build/nrepl.key" (or *load-truename* *default-pathname-defaults*))))
        (when (probe-file file)
          (setf *key* (with-open-file (in file) (read-line in nil nil))))))
    (cond
      ((equal cmd "eval") (cmd-eval port force-new positional))
      ((equal cmd "interrupt") (cmd-interrupt port))
      (t
       (format *error-output* "~&usage: nrepl.lisp eval|interrupt [--host H] [--port N] [--key K] [--new] [CODE]~%")
       (sb-ext:exit :code 2)))))

(main)
