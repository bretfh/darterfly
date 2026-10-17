(defpackage #:finch/nrepl
  (:use #:cl)
  (:export #:start #:stop #:running-p #:*port*))
(in-package #:finch/nrepl)

(defclass tcp-stream (sb-gray:fundamental-binary-input-stream sb-gray:fundamental-binary-output-stream)
  ((connection :initarg :connection :reader connection)
   (in :initform nil :accessor in)
   (at :initform 0 :accessor at)
   (out :initform (make-array 256 :element-type '(unsigned-byte 8) :adjustable t :fill-pointer 0) :reader out)))

(defmethod stream-element-type ((s tcp-stream)) '(unsigned-byte 8))

(defmethod sb-gray:stream-read-byte ((s tcp-stream))
  (loop while (or (null (in s)) (>= (at s) (length (in s))))
        do (let ((data (finch/net:tcp-receive (connection s))))
             (unless data (return-from sb-gray:stream-read-byte :eof))
             (setf (in s) data (at s) 0)))
  (prog1 (aref (in s) (at s)) (incf (at s))))

(defmethod sb-gray:stream-write-byte ((s tcp-stream) byte)
  (vector-push-extend byte (out s))
  byte)

(defmethod sb-gray:stream-write-sequence ((s tcp-stream) sequence &optional (start 0) end)
  (loop for i from start below (or end (length sequence)) do (vector-push-extend (elt sequence i) (out s)))
  sequence)

(defmethod sb-gray:stream-finish-output ((s tcp-stream))
  (when (plusp (length (out s)))
    (finch/net:tcp-send (connection s) (coerce (out s) '(simple-array (unsigned-byte 8) (*))))
    (setf (fill-pointer (out s)) 0))
  nil)

(defmethod sb-gray:stream-force-output ((s tcp-stream)) (sb-gray:stream-finish-output s))

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

(defun send (stream msg)
  (%write-value stream msg)
  (finish-output stream))

(defun %get (alist key &optional default)
  (let ((c (assoc key alist :test #'equal)))
    (if c (cdr c) default)))

(define-condition nrepl-interrupted (error) ()
  (:report "interrupted"))

(defstruct session
  (package (find-package :cl-user))
  (lock (sb-thread:make-mutex :name "nrepl session")))

(defvar *sessions* (make-hash-table :test 'equal))
(defvar *sessions-lock* (sb-thread:make-mutex :name "nrepl sessions"))
(defvar *session-counter* 0)

(defvar *running* (make-hash-table :test 'equal))
(defvar *running-lock* (sb-thread:make-mutex :name "nrepl running"))

(defun %register-running (id thread)
  (when id
    (sb-thread:with-mutex (*running-lock*)
      (setf (gethash id *running*) thread))))

(defun %unregister-running (id)
  (when id
    (sb-thread:with-mutex (*running-lock*)
      (remhash id *running*))))

(defun %running-thread (id)
  (and id
       (sb-thread:with-mutex (*running-lock*)
         (gethash id *running*))))

(defun %new-session-id ()
  (format nil "~x-~x" (get-internal-real-time) (incf *session-counter*)))

(defun %session (id)
  (sb-thread:with-mutex (*sessions-lock*)
    (gethash id *sessions*)))

(defun %clone-session (from-id)
  (sb-thread:with-mutex (*sessions-lock*)
    (let* ((pkg (let ((s (and from-id (gethash from-id *sessions*))))
                  (if s (session-package s) (find-package :cl-user))))
           (id (%new-session-id)))
      (setf (gethash id *sessions*) (make-session :package pkg))
      id)))

(defun %close-session (id)
  (sb-thread:with-mutex (*sessions-lock*)
    (remhash id *sessions*)))

(defun %flush (emit text)
  (let ((s (get-output-stream-string text)))
    (when (plusp (length s)) (funcall emit "out" s))))

(defun %eval-code (session code emit)
  (let ((*package* (session-package session))
        (eof (list nil)))
    (with-input-from-string (in code)
      (loop
        (let ((text (make-string-output-stream)))
          (handler-case
              (let ((form (read in nil eof)))
                (when (eq form eof) (return '("done")))
                (let* ((*standard-output* text) (*error-output* text)
                       (*compile-print* nil) (*compile-verbose* nil)
                       (value (handler-bind ((warning #'muffle-warning))
                                (eval form))))
                  (setf (session-package session) *package*)
                  (%flush emit text)
                  (funcall emit "value" (prin1-to-string value)
                                "ns" (package-name *package*))))
            (nrepl-interrupted ()
              (setf (session-package session) *package*)
              (%flush emit text)
              (funcall emit "err" (format nil "interrupted~%"))
              (return-from %eval-code '("interrupted" "done")))
            (serious-condition (c)
              (setf (session-package session) *package*)
              (%flush emit text)
              (funcall emit "err" (format nil "~a~%" c))
              (return-from %eval-code '("eval-error" "done")))))))))

(defun %eval-body (session sess-id code emit)
  (sb-thread:with-mutex ((session-lock session))
    (%register-running sess-id sb-thread:*current-thread*)
    (unwind-protect
         (funcall emit "status" (%eval-code session code
                                            (lambda (&rest kvs) (apply emit kvs))))
      (%unregister-running sess-id))))

(defun %spawn-eval (session sess-id code emit)
  (sb-thread:make-thread
   (lambda ()
     (catch '%abandon-eval
       (let ((sb-ext:*invoke-debugger-hook*
               (lambda (condition hook)
                 (declare (ignore hook))
                 (throw '%abandon-eval condition))))
         (handler-case (%eval-body session sess-id code emit)
           (error (e) (format *error-output* "~&nrepl eval: ~a~%" e))))))
   :name "nrepl eval"))

(defvar *key* nil)

(defun %handle-message (stream wlock msg)
  (let* ((op (%get msg "op"))
         (id (%get msg "id" "0"))
         (sess-id (%get msg "session")))
    (flet ((emit (&rest kvs)
             (sb-thread:with-mutex (wlock)
               (send stream
                     (apply #'%msg "id" id
                            (append (and sess-id (list "session" sess-id))
                                    kvs))))))
      (unless (and *key* (equal (%get msg "key") *key*))
        (emit "status" (list "unauthorized" "done"))
        (return-from %handle-message nil))
      (cond
        ((equal op "clone")
         (emit "new-session" (%clone-session sess-id) "status" (list "done")))
        ((equal op "close")
         (when sess-id (%close-session sess-id))
         (emit "status" (list "done")))
        ((equal op "describe")
         (emit "ops" (%msg "clone" (%msg) "eval" (%msg) "describe" (%msg)
                            "close" (%msg) "interrupt" (%msg))
               "versions" (%msg "finch-nrepl" (%msg "major" 0 "minor" 1))
               "status" (list "done")))
        ((equal op "interrupt")
         (let ((thread (%running-thread sess-id)))
           (if thread
               (progn
                 (sb-thread:interrupt-thread
                  thread (lambda () (error 'nrepl-interrupted)))
                 (emit "status" (list "done")))
               (emit "status" (list "session-idle" "done")))))
        ((equal op "eval")
         (let ((session (or (and sess-id (%session sess-id)) (make-session))))
           (%spawn-eval session sess-id (%get msg "code" "") #'emit)))
        (t (emit "status" (list "unknown-op" "done"))))
      t)))

(defvar *port* 4011)
(defvar *listener* nil)
(defvar *thread* nil)

(defun running-p () (and *thread* (sb-thread:thread-alive-p *thread*) t))

(defun %serve-one (connection)
  (let ((stream (make-instance 'tcp-stream :connection connection))
        (wlock (sb-thread:make-mutex :name "nrepl connection write")))
    (unwind-protect
         (loop (handler-case
                   (unless (%handle-message stream wlock (read-message stream))
                     (return))
                 (error () (return))))
      (ignore-errors (finch/net:tcp-close connection)))))

(defun %accept (listener)
  (loop (let ((connection (finch/net:tcp-accept listener)))
          (when connection
            (sb-thread:make-thread (lambda () (%serve-one connection))
                                   :name "nrepl connection")))))

(defun new-key ()
  (let ((state (make-random-state t)))
    (format nil "~{~(~8,'0x~)~}" (loop repeat 4 collect (random (ash 1 32) state)))))

(defun start (&key (port *port*) key)
  (unless finch/net:*interface*
    (finch/net:start-network))
  (setf *key* (or key
                  (let ((arg (finch/devices:boot-arg "nrepl-key"))) (and (stringp arg) arg))
                  *key*
                  (new-key)))
  (unless (running-p)
    (setf *port* port
          *listener* (finch/net:tcp-listen port)
          *thread* (sb-thread:make-thread (lambda () (%accept *listener*)) :name "nrepl listener")))
  (let ((address (format nil "~a:~d" (finch/net:address-string (finch/net::interface-ip finch/net:*interface*)) *port*)))
    (format t "~&nrepl: ~a key ~a~%" address *key*)
    address))

(defun stop ()
  (when *listener*
    (ignore-errors (finch/net:tcp-unlisten *listener*)))
  (when *thread*
    (ignore-errors (sb-thread:terminate-thread *thread*)))
  (setf *listener* nil *thread* nil)
  t)

(defun forget-server ()
  (setf *listener* nil *thread* nil
        *sessions* (make-hash-table :test 'equal) *sessions-lock* (sb-thread:make-mutex :name "nrepl sessions")
        *running* (make-hash-table :test 'equal) *running-lock* (sb-thread:make-mutex :name "nrepl running")))

(pushnew 'forget-server sb-ext:*save-hooks*)
