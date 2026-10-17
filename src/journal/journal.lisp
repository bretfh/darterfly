(defpackage #:darterfly/journal
  (:use #:cl)
  (:export #:note-form #:note-save #:forms-since-save #:replay #:trim #:*journal*))
(in-package #:darterfly/journal)

(defparameter *journal* "/Library/Logs/forms")

(defvar *journal-lock* (sb-thread:make-mutex :name "journal"))

(defun append-record (record)
  (sb-thread:with-mutex (*journal-lock*)
    (ensure-directories-exist *journal*)
    (with-open-file (s *journal* :direction :output :if-exists :append :if-does-not-exist :create)
      (with-standard-io-syntax
        (let ((*print-readably* nil))
          (prin1 record s)
          (terpri s))))
    record))

(defun note-form (text &key (origin :listener) (package *package*))
  (ignore-errors
   (append-record (list :form (get-universal-time) origin (package-name package) text))))

(defun note-save ()
  (append-record (list :saved (get-universal-time))))

(defun records ()
  (with-open-file (s *journal* :if-does-not-exist nil)
    (when s
      (with-standard-io-syntax
        (let ((*read-eval* nil))
          (loop for record = (handler-case (read s nil s) (error () s))
                until (eq record s)
                collect record))))))

(defun forms-since-save ()
  (let ((records (records)))
    (remove-if-not (lambda (r) (eq (first r) :form))
                   (let ((last (position :saved records :key #'first :from-end t)))
                     (if last (nthcdr (1+ last) records) records)))))

(defun replay (&optional (forms (forms-since-save)))
  (loop for (nil time origin package text) in forms
        collect (list time origin
                      (handler-case
                          (let ((*package* (or (find-package package) *package*)))
                            (with-input-from-string (in text)
                              (loop with eof = in
                                    for form = (read in nil eof)
                                    until (eq form eof)
                                    do (eval form)))
                            :ok)
                        (error (e) (list :error (princ-to-string e)))))))

(defun trim ()
  (sb-thread:with-mutex (*journal-lock*)
    (let* ((records (records))
           (last (position :saved records :key #'first :from-end t)))
      (when (and last (plusp last))
        (with-open-file (s *journal* :direction :output :if-exists :supersede)
          (with-standard-io-syntax
            (let ((*print-readably* nil))
              (dolist (r (nthcdr last records)) (prin1 r s) (terpri s)))))
        (darterfly/vfs:vfs-sync)
        (- (length records) (length (nthcdr last records)))))))
