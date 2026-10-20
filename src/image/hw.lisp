(in-package #:darterfly/image)

(defparameter *expected* '(:log :network :display :touchpad :disk :battery :audio :usb :wifi))

(defun health-on-device (host nrepl-port &optional (within 120))
  (read-answer (device-eval host "(darterfly/health:check)" :timeout (max 5 (ceiling within)) :nrepl-port nrepl-port)))

(defun health-rows-p (results)
  (and (consp results)
       (every (lambda (row) (and (consp row) (keywordp (first row)) (keywordp (second row)))) results)))

(defun health-failures (results &optional before)
  (if (not (health-rows-p results))
      (list (list :check :no-answer results))
      (row-failures results before)))

(defun row-failures (results before)
  (append
   (loop for (name status . detail) in results
         when (or (eq status :fail) (and (eq status :absent) (member name *expected*)))
           collect (list name status detail))
   (loop for name in *expected*
         unless (assoc name results)
           collect (list name :missing nil))
   (let ((was (getf (cddr (assoc :errors before)) :count))
         (now (getf (cddr (assoc :errors results)) :count)))
     (when (and was now (> now was))
       (list (list :errors :new (list (- now was) (getf (cddr (assoc :errors results)) :latest))))))))

(defun suspend-succeeded-p (reply)
  ;; The kernel returns the cumulative successful-wake count, not a boolean.
  (let ((count (and reply (ignore-errors (read-answer reply)))))
    (and (integerp count) (plusp count))))

(defun settle-health (host nrepl-port seconds)
  (let ((start (get-universal-time))
        (answered nil)
        (healthy-since nil))
    (loop with deadline = (+ start seconds)
          for left = (- deadline (get-universal-time))
          for results = (and (plusp left) (ignore-errors (health-on-device host nrepl-port (min 10 left))))
          when (and results (not answered)) do (setf answered (- (get-universal-time) start))
          do (if (and results (null (health-failures results)))
                 (unless healthy-since (setf healthy-since (get-universal-time)))
                 (setf healthy-since nil))
          ;; One successful rejoin can fail again seconds later. Require a
          ;; second healthy observation after ten seconds before passing.
          when (and healthy-since (>= (- (get-universal-time) healthy-since) 10))
            return (values results answered (- (get-universal-time) start))
          when (<= (- deadline (get-universal-time)) 0)
            return (values results answered nil)
          do (sleep (min 10 (max 0 (- deadline (get-universal-time))))))))

(defun hw (host &key label (sleep t) (wake-after 20) (settle 180) (nrepl-port 4011))
  (let* ((label (format nil "hw-~a" (or label host)))
         (before (health-on-device host nrepl-port))
         (slept (and sleep
                     (device-eval host (format nil "(darterfly/power:suspend :wake-after ~d)" wake-after) :timeout (+ wake-after 120) :nrepl-port nrepl-port)))
         (after nil) (answered nil) (healthy nil)
         (failures nil)
         (record nil))
    (when sleep
      (multiple-value-setq (after answered healthy) (settle-health host nrepl-port settle)))
    (setf failures (append (mapcar (lambda (f) (cons :before f)) (health-failures before))
                           (and sleep (not (suspend-succeeded-p slept)) (list (list :suspend :failed slept)))
                           (and sleep (mapcar (lambda (f) (cons :after f)) (health-failures after before))))
          record (list :label label :date (timestamp) :before before :slept slept :after after
                       :answered-after answered :healthy-after healthy :failures failures))
    (let ((dir (results-dir label)))
      (ensure-directories-exist dir)
      (with-open-file (s (merge-pathnames (format nil "~a.sexp" (getf record :date)) dir) :direction :output)
        (with-standard-io-syntax (let ((*print-pretty* t)) (prin1 record s))))
      (format t "~&~a ~a~%~12a ~8a ~8a ~a~%" label (getf record :date) "" "before" "after" "detail")
      (loop for (name status . detail) in before
            for later = (rest (assoc name after))
            do (format t "~12a ~8a ~8a ~s~%" (string-downcase name) (string-downcase status)
                       (if later (string-downcase (first later)) "") (or (rest later) detail)))
      (when slept
        (format t "suspend: ~a~%" (string-trim '(#\Newline #\Space) slept))
        (format t "answered ~:[never~;~:*~d s~] after suspend reply, healthy ~:[never~;~:*~d s~] after reply~%" answered healthy))
      (if failures
          (format t "~&FAILED~%~{  ~s~%~}" failures)
          (format t "~&ok~%"))
      (null failures))))
