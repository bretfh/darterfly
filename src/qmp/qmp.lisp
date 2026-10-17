(defpackage #:darterfly/qmp
  (:use #:cl)
  (:export #:qmp #:dict))
(in-package #:darterfly/qmp)

(defun dict (&rest kv)
  (let ((h (make-hash-table :test 'equal)))
    (loop :for (k v) :on kv :by #'cddr :do (setf (gethash k h) v))
    h))

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

(defun qmp (path command &optional arguments)
  (let ((socket (make-instance 'sb-bsd-sockets:local-socket :type :stream)))
    (unwind-protect
         (progn
           (sb-bsd-sockets:socket-connect socket (uiop:native-namestring path))
           (let ((s (sb-bsd-sockets:socket-make-stream socket :input t :output t
                                                               :external-format :utf-8
                                                               :buffering :full)))
             (qmp-line s)
             (qmp-execute s "qmp_capabilities" nil)
             (qmp-execute s command arguments)))
      (sb-bsd-sockets:socket-close socket))))
