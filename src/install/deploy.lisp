(in-package #:darterfly/install)

(defparameter *deploy-dir* "/Users/darterfly/deploy/")

(defun read-header (stream)
  (let ((octets (loop for b = (read-byte stream nil)
                      until (or (null b) (= b 10))
                      collect b)))
    (and octets (map 'string #'code-char octets))))

(defun read-stream-octets (stream length)
  (let ((v (make-array length :element-type '(unsigned-byte 8))))
    (loop with at = 0
          while (< at length)
          do (let ((n (read-sequence v stream :start at)))
               (when (= n at) (error "deploy: stream ended inside a file"))
               (setf at n)))
    v))

(defun same-octets-p (path octets)
  (let ((attr (ignore-errors (darterfly/vfs:vfs-stat path))))
    (and attr (= (darterfly/vfs:vattr-size attr) (length octets))
         (let ((fd (darterfly/vfs:vfs-open path (list :access :rdonly) 0)))
           (unwind-protect (equalp (darterfly/vfs:vfs-read fd (length octets)) octets)
             (darterfly/vfs:vfs-close fd))))))

(defun put-octets (path octets mode)
  (unless (same-octets-p path octets)
    (ensure-directories-exist path)
    (let ((fd (darterfly/vfs:vfs-open path (list :access :wronly :creat t :trunc t) mode)))
      (unwind-protect (darterfly/vfs:vfs-write fd octets)
        (darterfly/vfs:vfs-close fd)))
    (unless (same-octets-p path octets) (error "deploy: incomplete write to ~a" path))
    t))

(defun deployed-boot-conf ()
  (let ((flags (subseq (darterfly/devices:kernel-flags) 0 (search " -- " (darterfly/devices:kernel-flags)))))
    (format nil "kernel-flags=~{~a~^ ~} -- --core /System/Library/Kernels/darterfly.core~%ramdisk=/System/Library/RAMDisk/root.cpio~%"
            (substitute "init" "launchd" (uiop:split-string flags :separator " ") :test #'string=))))

(defvar *written* nil)

(defun deployment-target (kind path)
  (unless (and (member kind '("file" "gen") :test #'string=)
               (plusp (length path))
               (every (lambda (part) (and (plusp (length part)) (not (member part '("." "..") :test #'string=))))
                      (uiop:split-string path :separator "/")))
    (error "deploy: invalid path or file kind: ~s ~s" kind path))
  (concatenate 'string (if (string= kind "gen") *deploy-dir* "/") path))

(defun receive-files (stream stage &key (check-reload t))
  ;; Do not overwrite live sources until the complete transfer passes preflight.
  (let ((files nil) (kept 0))
    (unwind-protect
         (progn
           (loop for header = (read-header stream)
                 for index from 0
                 do (unless header (error "deploy: stream ended before end marker"))
                 until (string= header "end")
                 do (destructuring-bind (kind length mode &rest parts) (uiop:split-string header :separator " ")
                      (let* ((path (format nil "~{~a~^ ~}" parts))
                             (target (deployment-target kind path))
                             (octets (read-stream-octets stream (parse-integer length)))
                             (temporary (format nil "~a~d-~a" stage index (file-namestring target))))
                        (if (same-octets-p target octets)
                            (incf kept)
                            (progn
                              (push (list target temporary (parse-integer mode :radix 8)) files)
                              (put-octets temporary octets #o600))))))
           (let ((hazards (and check-reload
                               (reload-hazards (append (set-difference *written* (mapcar #'first files) :test #'string=)
                                                       (loop for (target temporary) in files
                                                             when (uiop:string-suffix-p target ".lisp") collect temporary))))))
             (when hazards (error "deploy refused before replacing files: ~{~a~^; ~}" hazards)))
           (dolist (file (reverse files))
             (destructuring-bind (target temporary mode) file
               (with-open-file (in temporary :element-type '(unsigned-byte 8))
                 (put-octets target (read-stream-octets in (file-length in)) mode))
               (when (uiop:string-suffix-p target ".lisp")
                 (pushnew target *written* :test #'string=))))
           (flush-disks)
           (list :written (length files) :unchanged kept))
      (dolist (file files) (ignore-errors (delete-file (second file))))
      (ignore-errors (uiop:delete-empty-directory stage)))))

(defun receive-deployment (host port &key (check-reload t))
  (let ((socket (make-instance 'sb-bsd-sockets:inet-socket :type :stream :protocol :tcp)))
    (unwind-protect
         (progn
           (sb-bsd-sockets:socket-connect socket (sb-bsd-sockets:make-inet-address host) port)
           (receive-files (sb-bsd-sockets:socket-make-stream socket :input t :element-type '(unsigned-byte 8) :buffering :full)
                          (format nil "~aincoming/~a/" *deploy-dir* (deployment-id)) :check-reload check-reload))
      (sb-bsd-sockets:socket-close socket))))

(defun receive-and-deploy (host port &key reload restart)
  (sb-thread:with-recursive-lock (*installing*)
    (when (or *saving* *deployment*) (error "a save or deployment is already under way"))
    (let ((id (unless reload (claim-deployment (deployment-id)))))
      (handler-case
          (append (receive-deployment host port)
                  (if reload (reload-systems) (continue-deployment id restart)))
        (error (e)
          (finish-deployment id :receive-failed (princ-to-string e))
          (list :receive-failed (princ-to-string e) :deployment id))))))

(defun source-forms (file)
  (let ((*package* (find-package "COMMON-LISP-USER"))
        (*read-eval* nil)
        (forms nil))
    (handler-case
        (with-open-file (s file)
          (loop for form = (read s nil s)
                until (eq form s)
                do (if (and (consp form) (eq (first form) 'in-package))
                       (let ((package (find-package (second form))))
                         (if package (setf *package* package) (return)))
                       (push form forms))))
      (error () nil))
    (nreverse forms)))

(defun struct-slot-names (name)
  (let ((dd (sb-kernel:find-defstruct-description name nil)))
    (and dd (mapcar (lambda (slot) (string (sb-kernel:dsd-name slot))) (sb-kernel:dd-slots dd)))))

(defun new-struct-slots (form)
  (destructuring-bind (name-and-options &rest slots) (rest form)
    (let* ((options (if (consp name-and-options) (rest name-and-options) nil))
           (include (find :include options :key (lambda (o) (if (consp o) (first o) o))))
           (own (mapcar (lambda (slot) (string (if (consp slot) (first slot) slot)))
                        (if (stringp (first slots)) (rest slots) slots))))
      (append (and (consp include) (struct-slot-names (second include))) own))))

(defun kernel-constant-p (name)
  (eq (symbol-package name) (find-package "DARTERFLY/KERN")))

(defun take-kernel-constant (condition)
  (when (and (typep condition 'sb-ext:defconstant-uneql)
             (kernel-constant-p (cell-error-name condition)))
    (continue condition)))

(defun only-read-p (symbol)
  (not (or (boundp symbol)
           (fboundp symbol)
           (symbol-plist symbol)
           (find-class symbol nil))))

(defun take-exported-symbol (condition)
  (when (and (typep condition 'sb-ext:name-conflict)
             (eq (sb-ext:name-conflict-function condition) 'export)
             (let ((incoming (let ((datum (sb-ext:name-conflict-datum condition)))
                               (if (listp datum) datum (list datum)))))
               (every (lambda (symbol)
                        (or (member symbol incoming)
                            (only-read-p symbol)))
                      (sb-ext:name-conflict-symbols condition))))
    (let ((take (find 'sb-impl::take-new (compute-restarts condition) :key #'restart-name)))
      (when take
        (invoke-restart take)))))

(defun form-hazard (form)
  (when (consp form)
    (case (first form)
      (defstruct
       (let* ((name (let ((n (second form))) (if (consp n) (first n) n)))
              (live (find-class name nil)))
         (cond ((null live) nil)
               ((not (typep live 'structure-class))
                (format nil "~s is a class in the running world; a struct can't take its name live" name))
               ((not (equal (struct-slot-names name) (new-struct-slots form)))
                (format nil "the struct ~s changes its slots from ~a to ~a" name (struct-slot-names name) (new-struct-slots form))))))
      (defclass
       (let ((live (find-class (second form) nil)))
         (when (typep live 'structure-class)
           (format nil "~s is a struct in the running world; a class can't take its name live" (second form)))))
      (defconstant
       (let ((name (second form)) (value (third form)))
         (when (and (symbolp name) (boundp name) (constantp name) (constantp value)
                    (not (kernel-constant-p name)))
           (let ((new (ignore-errors (eval value))))
             (unless (equalp new (symbol-value name))
               (format nil "the constant ~s changes from ~s to ~s" name (symbol-value name) new)))))))))

(defun reload-hazards (files)
  (loop for file in files
        append (loop for form in (source-forms file)
                     for hazard = (form-hazard form)
                     when hazard collect (format nil "~a: ~a" (file-namestring file) hazard))))

(defun deployment-id ()
  (format nil "~36r-~36r" (get-universal-time) (random (expt 2 40) (make-random-state t))))

(defun deploy-into-world (&key restart (id (deployment-id)))
  (sb-thread:with-recursive-lock (*installing*)
    (claim-deployment id)
    (handler-case (continue-deployment id restart)
      (error (e)
        (finish-deployment id :reload-failed (princ-to-string e))
        (list :reload-failed (princ-to-string e) :deployment id)))))

(defun continue-deployment (id restart)
  (let* ((kernel (concatenate 'string *deploy-dir* "kernel"))
         (loader (concatenate 'string *deploy-dir* "boot.efi"))
         (new-kernel (or restart
                         (and (probe-file kernel)
                          (not (same-octets-p "/System/Library/Kernels/kernel"
                                              (with-open-file (s kernel :element-type '(unsigned-byte 8))
                                                (let ((v (make-array (file-length s) :element-type '(unsigned-byte 8))))
                                                  (read-sequence v s) v)))))))
         (reloaded (handler-case (reload-systems)
                     (error (e)
                       (finish-deployment id :reload-failed (princ-to-string e))
                       (return-from continue-deployment (list :reload-failed (princ-to-string e) :deployment id))))))
    (when (getf reloaded :refused)
      (finish-deployment id :refused (getf reloaded :refused))
      (return-from continue-deployment (append reloaded (list :deployment id))))
    (note-deployment id :reloaded)
    (let ((darterfly/bsd:*recording* nil))
      (sb-thread:make-thread
       (lambda ()
         (sleep 2)
         (note-deployment id :saving)
         (handler-case
             (save-generation :deployment id :kernel (and (probe-file kernel) kernel)
                              :loader (and (probe-file loader) loader)
                              :boot-conf (deployed-boot-conf)
                              :restart new-kernel)
           (error (e) (finish-deployment id :save-failed (princ-to-string e)))))
       :name "deploy save"))
    (append reloaded (list :new-kernel (and new-kernel t) :saving t :deployment id))))

(defun reload-systems (&key force)
  (let ((hazards (and (not force) (reload-hazards *written*))))
    (when hazards
      (return-from reload-systems (list :refused hazards))))
  (let ((t0 (get-internal-real-time))
        (problems nil))
    (handler-bind ((error #'take-kernel-constant)
                   (sb-ext:name-conflict #'take-exported-symbol)
                   (warning (lambda (w)
                              (unless (typep w 'style-warning) (push (princ-to-string w) problems))
                              (muffle-warning w))))
      (unwind-protect
           (progn (setf darterfly/bsd::*reloading* t)
                  (asdf:load-system :darterfly)
                  (setf *written* nil))
        (setf darterfly/bsd::*reloaded* (get-internal-real-time)
              darterfly/bsd::*reloading* nil)))
    (list :seconds (/ (round (- (get-internal-real-time) t0) 100000) 10.0) :warnings (reverse problems))))

(defun flush-disks () (darterfly/power:flush-disks))
(defun restart-soon (&optional (seconds 2)) (darterfly/power:restart-soon seconds))
