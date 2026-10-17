(in-package #:darterfly/image)

(defun results-dir (label)
  (source (format nil "bench/results/~a/" label)))

(defun read-answer (text)
  (let ((at (search "=> " text)))
    (unless at (error "bench: no answer: ~a" text))
    (with-standard-io-syntax (let ((*read-eval* nil)) (read-from-string text t nil :start (+ at 3))))))

(defun bench-on-device (host)
  (read-answer (device-eval host "(darterfly/bench:run)" :timeout 900)))

(defun bench-in-vm ()
  (let ((c (bare-console :boot-args "init")))
    (unwind-protect
         (progn
           (expect c "init: pid 1" :timeout 120)
           (sleep 20)
           (send c "(format t \"~%BENCH ~s~%\" (darterfly/bench:run))")
           (let ((seen (expect c (format nil "~%* ") :timeout 900)))
             (with-standard-io-syntax
               (let ((*read-eval* nil)) (read-from-string seen t nil :start (+ 6 (search "BENCH " seen)))))))
      (finish c 5))))

(defun previous-results (dir)
  (let ((files (sort (directory (merge-pathnames "*.sexp" dir)) #'string> :key #'namestring)))
    (and files (with-open-file (s (first files)) (with-standard-io-syntax (let ((*read-eval* nil)) (read s)))))))

(defun timestamp ()
  (multiple-value-bind (s m h d mo y) (decode-universal-time (get-universal-time))
    (format nil "~d-~2,'0d-~2,'0d-~2,'0d~2,'0d~2,'0d" y mo d h m s)))

(defun bench (&key host label)
  (let* ((label (or label (if host host "vm")))
         (results (if host (bench-on-device host) (bench-in-vm)))
         (dir (results-dir label))
         (before (previous-results dir))
         (record (list :label label :date (timestamp) :results results)))
    (ensure-directories-exist dir)
    (with-open-file (s (merge-pathnames (format nil "~a.sexp" (getf record :date)) dir) :direction :output)
      (with-standard-io-syntax (let ((*print-pretty* t)) (prin1 record s))))
    (format t "~&~a ~a~%~32a ~12a ~12a ~a~%" label (getf record :date) "" "now" "before" "change")
    (dolist (r results record)
      (destructuring-bind (name value unit lower) r
        (let ((old (second (find name (getf before :results) :key #'first))))
          (format t "~32a ~12a ~12a ~a~%" (format nil "~(~a~) (~a)" name unit)
                  (if (realp value) (format nil "~,2f" value) value)
                  (if (realp old) (format nil "~,2f" old) "")
                  (if (and (realp value) (realp old) (plusp old))
                      (let ((change (* 100 (/ (- value old) old))))
                        (format nil "~@d%~a" (round change)
                                (cond ((< (abs change) 5) "") ((eq (minusp change) lower) " better") (t " worse"))))
                      "")))))))
