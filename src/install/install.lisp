(defpackage #:finch/install
  (:use #:cl)
  (:export #:install #:generations #:current #:save #:kernel-image #:build-kernel))
(in-package #:finch/install)

(defvar *esp* "/Volumes/EFI/")

(defun esp-path (name) (concatenate 'string *esp* "EFI/finch/" name))

(defun esp ()
  (unless (probe-file (esp-path "current")) (finch/fat:mount-esp (string-right-trim "/" *esp*)))
  (unless (probe-file (esp-path "current")) (error "no ESP with finch generations")))

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

(defun put-line (name text)
  (with-open-file (s (esp-path name) :direction :output :if-exists :supersede)
    (write-line text s)))

(defun stop-threads ()
  (finch/vfs:vfs-sync)
  (flet ((others ()
           (remove-if (lambda (th) (or (eq th sb-thread:*current-thread*) (sb-thread::thread-ephemeral-p th)
                                       (not (sb-thread:thread-alive-p th))))
                      (sb-thread:list-all-threads))))
    (mapc #'sb-thread:terminate-thread (others))
    (loop :repeat 200 :while (others) :do (sleep 0.05))
    (others)))

(defun save ()
  (let ((left (stop-threads)))
    (when left (error "threads still running: ~a" left)))
  (sb-ext:save-lisp-and-die "/System/Library/Kernels/saved.core"))

(defun install (kernel core)
  (let* ((was (current))
         (name (format nil "gen-~d" (1+ (reduce #'max (generations) :key (lambda (g) (parse-integer g :start 4)) :initial-value 0)))))
    (ensure-directories-exist (esp-path (format nil "~a/" name)))
    (uiop:copy-file kernel (esp-path (format nil "~a/kernel" name)))
    (uiop:copy-file core (esp-path (format nil "~a/finch.core" name)))
    (put-line "previous" was)
    (put-line "current" name)
    name))

(defun build-date ()
  (multiple-value-bind (s m h d mo y) (decode-universal-time (get-universal-time) 0)
    (format nil "~d-~2,'0d-~2,'0d ~2,'0d:~2,'0d:~2,'0d UTC" y mo d h m s)))

(defun kernel-image (user-objects)
  (setf finch/low:*build-date* (build-date))
  (finch/link:link-kernel
   (list (finch/link:read-object (finch/pexpert:pexpert-object) "pexpert.o" :kernel)
         (finch/link:read-object (finch/osfmk:osfmk-object) "osfmk.o" :kernel))
   (loop :for (name . octets) :in user-objects
         :collect (finch/link:read-object octets name :user))))

(defun read-octets (path)
  (with-open-file (s path :element-type '(unsigned-byte 8))
    (let ((v (make-array (file-length s) :element-type '(unsigned-byte 8))))
      (read-sequence v s)
      v)))

(defun build-kernel (&key (objects "/usr/lib/finch/objects/") (out "/Users/finch/kernel"))
  (let ((names (remove "" (uiop:split-string (uiop:read-file-string (concatenate 'string objects "objects"))
                                             :separator '(#\Newline))
                       :test #'string=)))
    (with-open-file (s out :direction :output :element-type '(unsigned-byte 8) :if-exists :supersede)
      (write-sequence (kernel-image (mapcar (lambda (name) (cons name (read-octets (concatenate 'string objects name))))
                                            names))
                      s))
    out))
