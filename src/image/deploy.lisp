(in-package #:darterfly/image)

(defun source-entries (&optional (root (asdf:system-relative-pathname :darterfly "")))
  ;; Include local source edits, but never sweep ignored VM disks, evidence or
  ;; compiler caches into the installed source tree. Source archives have no
  ;; Git metadata and retain the ordinary tree-copy path.
  (if (probe-file (merge-pathnames ".git" root))
      (loop for name in (uiop:split-string
                         (uiop:run-program
                           '("git" "ls-files" "--cached" "--others"
                             "--exclude-standard" "--deduplicate" "-z")
                           :directory root :output :string)
                         :separator (string #\Null))
            unless (or (zerop (length name)) (uiop:string-prefix-p "build/" name))
              append
              (let ((file (probe-file (merge-pathnames name root))))
                ;; A locally deleted tracked file must stay deleted.
                (when (and file (not (uiop:directory-pathname-p file)))
                  (list (list :file (concatenate 'string "usr/src/darterfly/" name)
                              (octets file)
                              (if (logtest #o111 (sb-posix:stat-mode
                                                  (sb-posix:stat (namestring file))))
                                  #o755 #o644)
                              (file-time file))))))
      (tree-entries root "usr/src/darterfly" :skip '(".git" "build"))))

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

(defun finish-deployment-server (server)
  (unless (sb-thread:join-thread server :default nil :timeout 5)
    (when (sb-thread:thread-alive-p server)
      (sb-thread:terminate-thread server)
      (sb-thread:join-thread server :default nil :timeout 5))))

(defun device-eval (host code &key (timeout 600) (nrepl-port 4011))
  (multiple-value-bind (out err status)
      (uiop:run-program (list "timeout" (princ-to-string timeout) "sbcl" "--script" (uiop:native-namestring (source "tools/nrepl.lisp"))
                              "eval" "--new" "--host" host "--port" (princ-to-string nrepl-port) "--key" (nrepl-key) code)
                        :output :string :error-output :string :ignore-error-status t)
    (unless (zerop status)
      (error "device evaluation failed (exit ~d): ~a~a" status out err))
    (concatenate 'string out err)))

(defun device-log (host &key (lines 100) (nrepl-port 4011))
  (device-eval host (format nil "(progn (write-string (darterfly/log:tail ~d)) (values))" lines) :timeout 60 :nrepl-port nrepl-port))

(defparameter *receiver-sources* '("src/power/power.lisp" "src/install/install.lisp" "src/install/deploy.lisp"))

(defun receiver-code ()
  (format nil "(progn ~{(with-input-from-string (s ~s) (let ((*package* (find-package \"DARTERFLY/INSTALL\"))) (loop for f = (read s nil s) until (eq f s) do (eval f)))) ~})"
          (mapcar (lambda (f) (uiop:read-file-string (source f))) *receiver-sources*)))

(defun address-toward (host)
  (let ((s (make-instance 'sb-bsd-sockets:inet-socket :type :datagram :protocol :udp)))
    (unwind-protect
         (progn (sb-bsd-sockets:socket-connect s (sb-bsd-sockets:make-inet-address host) 9)
                (format nil "~{~d~^.~}" (coerce (sb-bsd-sockets:socket-name s) 'list)))
      (sb-bsd-sockets:socket-close s))))

(defun push-generation (host &key (from (address-toward host)) (port 47100) (nrepl-port 4011))
  (let* ((entries (append (deployment :generation t) (list (list "gen" "darterfly.core" (octets (darterfly-core)) #o644))))
         (server (serve-deployment entries port)))
    (unwind-protect
         (device-eval host (format nil "(progn ~a (append (darterfly/install::receive-deployment ~s ~d :check-reload nil) (let ((dir darterfly/install::*deploy-dir*)) (list :generation (darterfly/install:install (concatenate 'string dir \"kernel\") (concatenate 'string dir \"darterfly.core\") :loader (concatenate 'string dir \"boot.efi\")) :restart (darterfly/power:restart-soon)))))"
                                           (receiver-code) from port)
                      :nrepl-port nrepl-port)
      (finish-deployment-server server))))

(defparameter *deploy-within* 1200)

(defun deployment-stages (host id nrepl-port)
  (let ((answer (ignore-errors
                 (read-answer (device-eval host (format nil "(darterfly/install::deployment-record ~s)" id)
                                           :timeout 30 :nrepl-port nrepl-port)))))
    (and (listp answer) answer)))

(defun deploy-outcome (host id &key (within *deploy-within*) (nrepl-port 4011))
  (let ((deadline (+ (get-universal-time) within))
        (seen nil))
    (loop
      (let ((stages (or (deployment-stages host id nrepl-port) seen)))
        (loop for entry in (nthcdr (length seen) stages)
              do (format t "~&deploy ~a: ~(~a~)~@[ ~s~]~%" id (first entry) (cddr entry)))
        (setf seen stages)
        (let ((last (first (car (last stages)))))
          (when (member last darterfly/install::*final-stages*)
            (return (values last stages))))
        (when (> (get-universal-time) deadline)
          (format t "~&deploy ~a: no final stage in ~d s, last ~(~a~)~%" id within (first (car (last stages))))
          (return (values :timed-out stages)))
        (sleep 10)))))

(defun deploy-and-wait (host &rest keys &key (nrepl-port 4011) &allow-other-keys)
  (let* ((result (apply #'deploy host keys))
         (at (search ":DEPLOYMENT \"" result))
         (id (and at (subseq result (+ at 13) (position #\" result :start (+ at 13))))))
    (format t "~&~a~%" (string-trim '(#\Newline #\Space) result))
    (if id
        (eq :healthy (deploy-outcome host id :nrepl-port nrepl-port))
        (progn (format t "~&deploy: the device gave no deployment id~%") nil))))

(defun deploy (host &key (from (address-toward host)) (port 47100) (nrepl-port 4011) (reload nil) (restart nil))
  (let* ((entries (deployment :generation (not reload)))
         (server (serve-deployment entries port)))
    (unwind-protect
         (device-eval host (format nil "(sb-thread:with-recursive-lock (darterfly/install::*installing*) (when (or darterfly/install::*saving* darterfly/install::*deployment*) (error \"a save or deployment is already under way\")) ~a (darterfly/install::receive-and-deploy ~s ~d :reload ~a :restart ~a))"
                                           (receiver-code) from port (and reload t) (and restart t))
                      :nrepl-port nrepl-port)
      (finish-deployment-server server))))
