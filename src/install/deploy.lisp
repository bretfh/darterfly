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
    t))

(defun deployed-boot-conf ()
  (let ((flags (subseq (darterfly/devices:kernel-flags) 0 (search " -- " (darterfly/devices:kernel-flags)))))
    (format nil "kernel-flags=~{~a~^ ~} -- --core /System/Library/Kernels/darterfly.core~%ramdisk=/System/Library/RAMDisk/root.cpio~%"
            (substitute "init" "launchd" (uiop:split-string flags :separator " ") :test #'string=))))

(defvar *written* nil)

(defun receive-deployment (host port)
  (let ((socket (make-instance 'sb-bsd-sockets:inet-socket :type :stream :protocol :tcp))
        (written nil) (kept 0))
    (sb-bsd-sockets:socket-connect socket (sb-bsd-sockets:make-inet-address host) port)
    (unwind-protect
         (let ((stream (sb-bsd-sockets:socket-make-stream socket :input t :element-type '(unsigned-byte 8) :buffering :full)))
           (loop for header = (read-header stream)
                 until (or (null header) (string= header "end"))
                 do (destructuring-bind (kind length mode &rest path) (uiop:split-string header :separator " ")
                      (let ((path (format nil "~{~a~^ ~}" path))
                            (octets (read-stream-octets stream (parse-integer length))))
                        (if (if (string= kind "gen")
                                (put-octets (concatenate 'string *deploy-dir* path) octets #o644)
                                (put-octets (concatenate 'string "/" path) octets (parse-integer mode :radix 8)))
                            (push path written)
                            (incf kept))))))
      (sb-bsd-sockets:socket-close socket))
    (flush-disks)
    (setf *written* (union *written*
                           (loop for path in written
                                 when (uiop:string-suffix-p path ".lisp")
                                   collect (concatenate 'string "/" path))
                           :test #'string=))
    (list :written (length written) :unchanged kept)))


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
         (when (and (symbolp name) (boundp name) (constantp name) (constantp value))
           (let ((new (ignore-errors (eval value))))
             (unless (equalp new (symbol-value name))
               (format nil "the constant ~s changes from ~s to ~s" name (symbol-value name) new)))))))))

(defun reload-hazards (files)
  (loop for file in files
        append (loop for form in (source-forms file)
                     for hazard = (form-hazard form)
                     when hazard collect (format nil "~a: ~a" (file-namestring file) hazard))))

(defun deploy-into-world (&key restart)
  (let* ((kernel (concatenate 'string *deploy-dir* "kernel"))
         (loader (concatenate 'string *deploy-dir* "boot.efi"))
         (new-kernel (or restart
                         (and (probe-file kernel)
                          (not (same-octets-p "/System/Library/Kernels/kernel"
                                              (with-open-file (s kernel :element-type '(unsigned-byte 8))
                                                (let ((v (make-array (file-length s) :element-type '(unsigned-byte 8))))
                                                  (read-sequence v s) v)))))))
         (reloaded (reload-systems)))
    (when (getf reloaded :refused)
      (return-from deploy-into-world reloaded))
    (let ((darterfly/bsd:*recording* nil))
      (sb-thread:make-thread
       (lambda ()
         (sleep 2)
         (save-generation :kernel (and (probe-file kernel) kernel)
                        :loader (and (probe-file loader) loader)
                        :boot-conf (deployed-boot-conf)
                          :restart new-kernel))
       :name "deploy save"))
    (append reloaded (list :new-kernel (and new-kernel t) :saving t))))

(defun reload-systems (&key force)
  (let ((hazards (and (not force) (reload-hazards *written*))))
    (when hazards
      (return-from reload-systems (list :refused hazards))))
  (let ((t0 (get-internal-real-time))
        (problems nil))
    (handler-bind ((warning (lambda (w)
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
