(in-package #:darterfly/image)

(defun source-entries ()
  (tree-entries (asdf:system-relative-pathname :darterfly "") "usr/src/darterfly" :skip '(".git" "build")))

(defun deployment (&key (generation t))
  (append (loop for entry in (if generation (root-entries) (source-entries))
                when (eq (first entry) :file)
                  collect (destructuring-bind (path octets &optional (mode #o644) &rest more) (rest entry)
                            (declare (ignore more))
                            (list "file" path octets mode)))
          (and generation
               (list (list "gen" "kernel" (octets (kernel-file)) #o644)
                     (list "gen" "boot.efi" (octets (boot-efi)) #o644)))))

(defun serve-deployment (entries port)
  (let ((listener (make-instance 'sb-bsd-sockets:inet-socket :type :stream :protocol :tcp)))
    (setf (sb-bsd-sockets:sockopt-reuse-address listener) t)
    (sb-bsd-sockets:socket-bind listener #(0 0 0 0) port)
    (sb-bsd-sockets:socket-listen listener 1)
    (sb-thread:make-thread
     (lambda ()
       (unwind-protect
            (let* ((socket (sb-bsd-sockets:socket-accept listener))
                   (stream (sb-bsd-sockets:socket-make-stream socket :output t :element-type '(unsigned-byte 8) :buffering :full)))
              (unwind-protect
                   (progn
                     (loop for (kind path octets mode) in entries
                           do (write-sequence (text (format nil "~a ~d ~o ~a~%" kind (length octets) mode path)) stream)
                              (write-sequence octets stream))
                     (write-sequence (text (format nil "end~%")) stream)
                     (finish-output stream))
                (sb-bsd-sockets:socket-close socket)))
         (sb-bsd-sockets:socket-close listener)))
     :name "deployment")))

(defun device-eval (host code &key (timeout 600) (nrepl-port 4011))
  (multiple-value-bind (out err)
      (uiop:run-program (list "timeout" (princ-to-string timeout) "sbcl" "--script" (uiop:native-namestring (source "tools/nrepl.lisp"))
                              "eval" "--new" "--host" host "--port" (princ-to-string nrepl-port) "--key" (nrepl-key) code)
                        :output :string :error-output :string :ignore-error-status t)
    (concatenate 'string out err)))

(defparameter *receiver-sources* '("src/power/power.lisp" "src/install/deploy.lisp"))

(defun receiver-code ()
  (format nil "(progn ~{(with-input-from-string (s ~s) (let ((*package* (find-package \"DARTERFLY/INSTALL\"))) (loop for f = (read s nil s) until (eq f s) do (eval f)))) ~})"
          (mapcar (lambda (f) (uiop:read-file-string (source f))) *receiver-sources*)))

(defun deploy (host &key (from "10.42.0.1") (port 47100) (nrepl-port 4011) (reload nil))
  (let* ((entries (deployment :generation (not reload)))
         (server (serve-deployment entries port))
         (result (device-eval host (format nil "(progn ~a (append (darterfly/install::receive-deployment ~s ~d) (~a)))"
                                           (receiver-code) from port
                                           (if reload "darterfly/install::reload-systems" "darterfly/install::deploy-into-world"))
                              :nrepl-port nrepl-port)))
    (sb-thread:join-thread server :default nil :timeout 5)
    result))
