(defpackage #:darterfly/install
  (:use #:cl)
  (:export #:*stable-after* #:deploy-into-world #:save-generation #:heap-errors #:bad-world #:install-saved-generation #:receive-deployment #:reload-systems #:restart-soon #:flush-disks #:install #:generations #:current #:select #:confirm #:failed #:manifest #:save #:stop-threads #:kernel-image #:build-kernel #:install-disk #:internal-disk))
(in-package #:darterfly/install)

(defvar *esp* "/Volumes/EFI/")

(defun esp-path (name) (concatenate 'string *esp* "EFI/darterfly/" name))

(defun esp ()
  (unless (probe-file (esp-path "current")) (darterfly/fat:mount-esp (string-right-trim "/" *esp*)))
  (unless (probe-file (esp-path "current")) (error "no ESP with darterfly generations")))

(defun generations ()
  (esp)
  (sort (loop :for dir :in (uiop:subdirectories (esp-path ""))
              :for name := (car (last (pathname-directory dir)))
              :when (uiop:string-prefix-p "gen-" name)
                :collect name)
        #'< :key (lambda (name) (parse-integer name :start 4))))

(defun current ()
  (esp)
  (string-trim '(#\Newline #\Space) (uiop:read-file-string (esp-path "current"))))

(defun manifest (name)
  (let ((path (esp-path (format nil "~a/manifest" name))))
    (when (probe-file path)
      (with-open-file (s path) (with-standard-io-syntax (let ((*read-eval* nil)) (read s)))))))

(defun put-text (name text)
  (let ((fresh (esp-path (concatenate 'string name ".new"))))
    (with-open-file (s fresh :direction :output :if-exists :supersede)
      (write-string text s))
    (darterfly/power:flush-disks)
    (darterfly/vfs:vfs-rename fresh (esp-path name))
    (darterfly/power:flush-disks)))

(defun put-line (name text) (put-text name (format nil "~a~%" text)))

(defun link (name)
  (let ((path (esp-path name)))
    (when (probe-file path)
      (string-trim '(#\Newline #\Space) (uiop:read-file-string path)))))

(defun failed () (link "failed"))

(defun confirm ()
  (esp)
  (let ((name (current)))
    (unless (equal name (link "good"))
      (put-line "good" name))
    (uiop:delete-file-if-exists (esp-path "tried"))
    name))

(defun select (name)
  (unless (member name (generations) :test #'string=)
    (error "no generation ~a" name))
  (let ((was (current)))
    (unless (string= was name)
      (put-line "previous" was)
      (put-line "current" name)))
  name)

(defun stop-threads (&optional keep)
  (darterfly/worlds:quiet-watchdog)
  (darterfly/vfs:vfs-sync)
  (flet ((others ()
           (remove-if (lambda (th) (or (eq th sb-thread:*current-thread*) (sb-thread::thread-ephemeral-p th)
                                       (member th keep) (not (sb-thread:thread-alive-p th))))
                      (sb-thread:list-all-threads))))
    (mapc #'sb-thread:terminate-thread (others))
    (loop :repeat 200 :while (others) :do (sleep 0.05))
    (others)))

(defparameter *pending-generation* "/Library/Settings/pending-generation")

(defvar *installing* (sb-thread:make-mutex :name "installing"))

(defun save-failed (condition)
  (format *error-output* "~&save failed: ~a~%save: the world carries on unsaved~%" condition)
  (handler-case (delete-file *pending-generation*)
    (error (e) (format *error-output* "~&save: pending generation: ~a~%" e)))
  (handler-case (darterfly/journal::unsave)
    (error (e) (format *error-output* "~&save: journal: ~a~%" e)))
  (handler-case (darterfly/power:flush-disks)
    (error (e) (format *error-output* "~&save: flush: ~a~%" e)))
  (unless (typep condition 'sb-impl::save-error)
    (sb-impl::call-hooks "save" sb-ext:*save-hooks* :on-error :warn)
    (sb-impl::call-hooks "initialization" sb-ext:*init-hooks* :on-error :warn)))

(defun save ()
  (handler-case
      (progn
        (let ((left (stop-threads)))
          (when left (error "threads still running: ~a" left)))
        (sb-ext:save-lisp-and-die "/System/Library/Kernels/saved.core"))
    (error (e) (save-failed e) nil)))

(define-condition bad-world (error)
  ((errors :initarg :errors :reader bad-world-errors))
  (:report (lambda (c s) (format s "the world has ~d heap errors; it is not saved" (bad-world-errors c)))))

(defun runtime-function (name)
  (or (sb-sys:find-foreign-symbol-address name) (error "the runtime has no ~a" name)))

(defun heap-errors ()
  (let ((verify (sb-sys:find-foreign-symbol-address "darterfly_heap_errors"))
        (lock (runtime-function "try_acquire_gc_lock"))
        (unlock (runtime-function "release_gc_lock"))
        (result nil))
    (unless verify (return-from heap-errors nil))
    (sb-sys:without-gcing
      (when (eql 1 (sb-alien:alien-funcall (sb-alien:sap-alien (sb-sys:int-sap lock) (function sb-alien:int))))
        (sb-kernel::gc-stop-the-world)
        (unwind-protect
             (setq result (sb-alien:alien-funcall (sb-alien:sap-alien (sb-sys:int-sap verify) (function sb-alien:int))))
          (sb-kernel::gc-start-the-world)
          (sb-alien:alien-funcall (sb-alien:sap-alien (sb-sys:int-sap unlock) (function sb-alien:void))))))
    (or result (error "could not stop the world to check the heap"))))

(defparameter *stable-after* 90)

(defun save-generation (&key kernel loader boot-conf restart then)
  (let ((errors (heap-errors)))
    (when (null errors) (format *error-output* "~&save: this runtime can't check the heap; saving unchecked~%"))
    (when (and errors (plusp errors)) (error 'bad-world :errors errors)))
  (sb-thread:with-mutex (*installing*))
  (darterfly/journal:note-save)
  (ensure-directories-exist *pending-generation*)
  (with-open-file (s *pending-generation* :direction :output :if-exists :supersede)
    (with-standard-io-syntax
      (prin1 (list :kernel kernel :loader loader :boot-conf boot-conf
                   :restart (or restart (eq then :restart)) :shut-down (eq then :shut-down))
             s)))
  (darterfly/bsd:suspend-processes)
  (darterfly/bsd:suspend-threads)
  (darterfly/bsd:end-processes)
  (darterfly/power:flush-disks)
  (if (eq sb-thread:*current-thread* (sb-thread:main-thread))
      (save)
      (sb-thread:interrupt-thread (sb-thread:main-thread) #'save)))

(defun install-saved-generation ()
  (sb-thread:with-mutex (*installing*)
    (install-pending)))

(defun install-pending ()
  (when (probe-file *pending-generation*)
    (let ((pending (ignore-errors (with-open-file (s *pending-generation*)
                                    (with-standard-io-syntax (let ((*read-eval* nil)) (read s)))))))
      (prog1 (install (or (getf pending :kernel) "/System/Library/Kernels/kernel")
                      "/System/Library/Kernels/darterfly.core"
                      :loader (getf pending :loader))
        (delete-file *pending-generation*)
        (ignore-errors (darterfly/journal:trim))
        (when (getf pending :boot-conf)
          (put-text "boot.conf" (getf pending :boot-conf)))
        (darterfly/power:flush-disks)
        (cond ((getf pending :shut-down) (darterfly/power:shut-down))
              ((getf pending :restart) (darterfly/power:restart)))))))

(defparameter *kept-generations* 3)

(defun remove-generation (name)
  (let ((dir (esp-path (format nil "~a/" name))))
    (mapc #'delete-file (uiop:directory-files dir))
    (uiop:delete-empty-directory dir)))

(defun prune-generations (&optional (keep *kept-generations*))
  (let* ((linked (remove nil (list (current) (link "previous") (link "good") (link "failed"))))
         (all (generations))
         (newest (last all keep)))
    (dolist (g all)
      (unless (or (member g linked :test #'string=) (member g newest :test #'string=))
        (remove-generation g)))))

(defun install (kernel core &key loader manifest)
  (prune-generations (1- *kept-generations*))
  (let* ((was (current))
         (name (format nil "gen-~d" (1+ (reduce #'max (generations) :key (lambda (g) (parse-integer g :start 4)) :initial-value 0)))))
    (handler-bind ((error (lambda (e) (declare (ignore e)) (ignore-errors (remove-generation name)))))
      (ensure-directories-exist (esp-path (format nil "~a/" name)))
      (uiop:copy-file kernel (esp-path (format nil "~a/kernel" name)))
      (uiop:copy-file core (esp-path (format nil "~a/darterfly.core" name)))
      (when manifest
        (uiop:copy-file manifest (esp-path (format nil "~a/manifest" name))))
      (when loader
        (uiop:copy-file loader (esp-path (format nil "~a/boot.efi" name)))
        (uiop:copy-file loader (concatenate 'string *esp* "EFI/BOOT/BOOTX64.EFI"))))
    (put-line "previous" was)
    (put-line "current" name)
    name))

(defun build-date (time)
  (multiple-value-bind (s m h d mo y) (decode-universal-time time 0)
    (format nil "~d-~2,'0d-~2,'0d ~2,'0d:~2,'0d:~2,'0d UTC" y mo d h m s)))

(defun kernel-image (user-objects &key (date (get-universal-time)))
  (setf darterfly/low:*build-date* (build-date date))
  (darterfly/link:link-kernel
   (list (darterfly/link:read-object (darterfly/platform:platform-object) "platform.o" :kernel)
         (darterfly/link:read-object (darterfly/kern:kern-object) "kern.o" :kernel))
   (cons (darterfly/link:read-object (darterfly/libsa:libsa-object) "libsa.o" :user)
         (loop :for (name . octets) :in user-objects
               :collect (darterfly/link:read-object octets name :user)))))

(defun read-octets (path)
  (with-open-file (s path :element-type '(unsigned-byte 8))
    (let ((v (make-array (file-length s) :element-type '(unsigned-byte 8))))
      (read-sequence v s)
      v)))

(defun build-kernel (&key (objects "/usr/lib/darterfly/objects/") (out "/Users/darterfly/kernel"))
  (let ((names (remove "" (uiop:split-string (uiop:read-file-string (concatenate 'string objects "objects"))
                                             :separator '(#\Newline))
                       :test #'string=)))
    (with-open-file (s out :direction :output :element-type '(unsigned-byte 8) :if-exists :supersede)
      (write-sequence (kernel-image (mapcar (lambda (name) (cons name (read-octets (concatenate 'string objects name))))
                                            names)
                                    :date (reduce #'max names :key (lambda (name) (file-write-date (concatenate 'string objects name)))
                                                              :initial-value 0))
                      s))
    out))

(setf darterfly/power:*save-system* 'save-generation)
