(defpackage #:darterfly/install
  (:use #:cl)
  (:export #:deploy-into-world #:save-generation #:install-saved-generation #:receive-deployment #:reload-systems #:restart-soon #:flush-disks #:install #:generations #:current #:select #:confirm #:failed #:manifest #:save #:stop-threads #:kernel-image #:build-kernel #:install-disk #:internal-disk))
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

(defun put-line (name text)
  (with-open-file (s (esp-path name) :direction :output :if-exists :supersede)
    (write-line text s)))

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
  (darterfly/vfs:vfs-sync)
  (flet ((others ()
           (remove-if (lambda (th) (or (eq th sb-thread:*current-thread*) (sb-thread::thread-ephemeral-p th)
                                       (member th keep) (not (sb-thread:thread-alive-p th))))
                      (sb-thread:list-all-threads))))
    (mapc #'sb-thread:terminate-thread (others))
    (loop :repeat 200 :while (others) :do (sleep 0.05))
    (others)))

(defun save ()
  (let ((left (stop-threads)))
    (when left (error "threads still running: ~a" left)))
  (sb-ext:save-lisp-and-die "/System/Library/Kernels/saved.core"))

(defparameter *pending-generation* "/Library/Settings/pending-generation")

(defun save-generation (&key kernel loader boot-conf restart)
  (ensure-directories-exist *pending-generation*)
  (with-open-file (s *pending-generation* :direction :output :if-exists :supersede)
    (with-standard-io-syntax
      (prin1 (list :kernel kernel :loader loader :boot-conf boot-conf :restart restart) s)))
  (darterfly/bsd:suspend-processes)
  (darterfly/bsd:suspend-threads)
  (darterfly/bsd:end-processes)
  (darterfly/power:flush-disks)
  (if (eq sb-thread:*current-thread* (sb-thread:main-thread))
      (save)
      (sb-thread:interrupt-thread (sb-thread:main-thread) #'save)))

(defun install-saved-generation ()
  (when (probe-file *pending-generation*)
    (let ((pending (ignore-errors (with-open-file (s *pending-generation*)
                                    (with-standard-io-syntax (let ((*read-eval* nil)) (read s)))))))
      (delete-file *pending-generation*)
      (prog1 (install (or (getf pending :kernel) "/System/Library/Kernels/kernel")
                      "/System/Library/Kernels/darterfly.core"
                      :loader (getf pending :loader))
        (when (getf pending :boot-conf)
          (with-open-file (s (esp-path "boot.conf") :direction :output :if-exists :supersede)
            (write-string (getf pending :boot-conf) s)))
        (darterfly/power:flush-disks)
        (when (getf pending :restart)
          (darterfly/power:restart))))))

(defun install (kernel core &key loader manifest)
  (let* ((was (current))
         (name (format nil "gen-~d" (1+ (reduce #'max (generations) :key (lambda (g) (parse-integer g :start 4)) :initial-value 0)))))
    (ensure-directories-exist (esp-path (format nil "~a/" name)))
    (uiop:copy-file kernel (esp-path (format nil "~a/kernel" name)))
    (uiop:copy-file core (esp-path (format nil "~a/darterfly.core" name)))
    (when manifest
      (uiop:copy-file manifest (esp-path (format nil "~a/manifest" name))))
    (when loader
      (uiop:copy-file loader (esp-path (format nil "~a/boot.efi" name)))
      (uiop:copy-file loader (concatenate 'string *esp* "EFI/BOOT/BOOTX64.EFI")))
    (put-line "previous" was)
    (put-line "current" name)
    name))

(defun build-date ()
  (multiple-value-bind (s m h d mo y) (decode-universal-time (get-universal-time) 0)
    (format nil "~d-~2,'0d-~2,'0d ~2,'0d:~2,'0d:~2,'0d UTC" y mo d h m s)))

(defun kernel-image (user-objects)
  (setf darterfly/low:*build-date* (build-date))
  (darterfly/link:link-kernel
   (list (darterfly/link:read-object (darterfly/platform:platform-object) "platform.o" :kernel)
         (darterfly/link:read-object (darterfly/kern:kern-object) "kern.o" :kernel))
   (loop :for (name . octets) :in user-objects
         :collect (darterfly/link:read-object octets name :user))))

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
                                            names))
                      s))
    out))

(setf darterfly/power:*save-system* 'save-generation)
