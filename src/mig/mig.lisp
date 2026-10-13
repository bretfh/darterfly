(defpackage #:finch/mig
  (:use #:cl)
  (:export
   #:subsystems #:subsystem #:subsystem-name #:subsystem-address #:subsystem-server
   #:subsystem-start #:subsystem-end #:subsystem-maxsize #:subsystem-routines
   #:routine #:routine-id #:routine-name #:routine-stub #:routine-impl #:routine-argc
   #:routine-descr-count #:routine-max-reply-msg
   #:form #:write-subsystems))
(in-package #:finch/mig)

(defstruct subsystem name address server start end maxsize routines)
(defstruct routine id name stub impl argc descr-count max-reply-msg)

(defun le (o at count)
  (loop :with n := 0
        :for i :from (+ at count -1) :downto at
        :do (setf n (logior (ash n 8) (aref o i)))
        :finally (return n)))

(defun suffixp (suffix string)
  (let ((n (- (length string) (length suffix))))
    (and (>= n 0) (string= suffix string :start2 n))))

(defun c-name (symbol)
  (if (and (plusp (length symbol)) (char= #\_ (char symbol 0))) (subseq symbol 1) symbol))

(defun routine-name-of (stub names)
  (let ((name (c-name (gethash stub names ""))))
    (if (and (> (length name) 2) (string= "_X" name :end2 2)) (subseq name 2) name)))

(defun read-subsystem (image name address names)
  (let* ((head (finch/macho:read-address image address 32))
         (start (le head 8 4))
         (end (le head 12 4))
         (body (finch/macho:read-address image (+ address 32) (* 40 (- end start)))))
    (make-subsystem
     :name (c-name name) :address address :server (le head 0 8)
     :start start :end end :maxsize (le head 16 4)
     :routines (loop :for i :below (- end start)
                     :for at := (* 40 i)
                     :for stub := (le body (+ at 8) 8)
                     :unless (zerop stub)
                       :collect (make-routine :id (+ start i) :stub stub
                                              :name (routine-name-of stub names)
                                              :impl (le body at 8)
                                              :argc (le body (+ at 16) 4)
                                              :descr-count (le body (+ at 20) 4)
                                              :max-reply-msg (le body (+ at 32) 4))))))

(defun subsystems (image)
  (let ((names (make-hash-table))
        (symbols (finch/macho:symbols image)))
    (dolist (s symbols)
      (unless (zerop (finch/macho:nlist-value s))
        (setf (gethash (finch/macho:nlist-value s) names) (finch/macho:nlist-name s))))
    (sort (loop :for s :in symbols
                :for name := (finch/macho:nlist-name s)
                :when (and (suffixp "_subsystem" name) (/= 1 (logand 1 (finch/macho:nlist-type s)))
                           (not (zerop (finch/macho:nlist-value s))))
                  :collect (read-subsystem image name (finch/macho:nlist-value s) names))
          #'< :key #'subsystem-start)))

(defun form (subsystem)
  `(:subsystem ,(subsystem-name subsystem) :start ,(subsystem-start subsystem)
    :end ,(subsystem-end subsystem) :maxsize ,(subsystem-maxsize subsystem)
    :routines ,(mapcar (lambda (r) (list (routine-id r) (routine-name r)
                                         :argc (routine-argc r)
                                         :max-reply-msg (routine-max-reply-msg r)))
                       (subsystem-routines subsystem))))

(defun write-subsystems (image destination)
  (ensure-directories-exist destination)
  (with-open-file (out destination :direction :output :if-exists :supersede)
    (with-standard-io-syntax
      (let ((*print-pretty* t) (*print-right-margin* 100))
        (dolist (s (subsystems image) (probe-file destination))
          (print (form s) out)
          (terpri out))))))
