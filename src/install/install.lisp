(defpackage #:finch/install
  (:use #:cl)
  (:export #:install #:generations #:current #:save))
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
