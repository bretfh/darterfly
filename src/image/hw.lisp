(in-package #:darterfly/image)

(defparameter *expected* '(:log :network :display :touchpad :disk :battery :audio :usb :wifi))

(defun health-on-device (host nrepl-port)
  (read-answer (device-eval host "(darterfly/health:check)" :timeout 120 :nrepl-port nrepl-port)))

(defun health-failures (results &optional before)
  (append
   (loop for (name status . detail) in results
         when (or (eq status :fail) (and (eq status :absent) (member name *expected*)))
           collect (list name status detail))
   (let ((was (getf (cddr (assoc :errors before)) :count))
         (now (getf (cddr (assoc :errors results)) :count)))
     (when (and was now (> now was))
       (list (list :errors :new (list (- now was) (getf (cddr (assoc :errors results)) :latest))))))))

(defun settle-health (host nrepl-port seconds)
  (loop with deadline = (+ (get-universal-time) seconds)
        for results = (ignore-errors (health-on-device host nrepl-port))
        when (and results (null (health-failures results))) return results
        when (> (get-universal-time) deadline) return results
        do (sleep 10)))

(defun hw (host &key label (sleep t) (wake-after 20) (settle 180) (nrepl-port 4011))
  (let* ((label (format nil "hw-~a" (or label host)))
         (before (health-on-device host nrepl-port))
         (slept (and sleep
                     (device-eval host (format nil "(darterfly/power:suspend :wake-after ~d)" wake-after) :timeout (+ wake-after 120) :nrepl-port nrepl-port)))
         (after (and sleep (settle-health host nrepl-port settle)))
         (failures (append (mapcar (lambda (f) (cons :before f)) (health-failures before))
                           (and sleep (null after) (list (list :after :no-answer)))
                           (mapcar (lambda (f) (cons :after f)) (health-failures after before))))
         (record (list :label label :date (timestamp) :before before :slept slept :after after :failures failures))
         (dir (results-dir label)))
    (ensure-directories-exist dir)
    (with-open-file (s (merge-pathnames (format nil "~a.sexp" (getf record :date)) dir) :direction :output)
      (with-standard-io-syntax (let ((*print-pretty* t)) (prin1 record s))))
    (format t "~&~a ~a~%~12a ~8a ~8a ~a~%" label (getf record :date) "" "before" "after" "detail")
    (loop for (name status . detail) in before
          for later = (rest (assoc name after))
          do (format t "~12a ~8a ~8a ~s~%" (string-downcase name) (string-downcase status)
                     (if later (string-downcase (first later)) "") (or (rest later) detail)))
    (when slept (format t "suspend: ~a~%" (string-trim '(#\Newline #\Space) slept)))
    (if failures
        (format t "~&FAILED~%~{  ~s~%~}" failures)
        (format t "~&ok~%"))
    (null failures)))
