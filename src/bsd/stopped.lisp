(in-package #:darterfly/bsd)

(defparameter *keep-stopped-for* 600)

(defparameter *system-locks*
  '(("DARTERFLY/BSD" "*BSD*")
    ("DARTERFLY/VFS" "*LOCK*")
    ("DARTERFLY/MACH" "*IPC*")
    ("DARTERFLY/APFS" "*DIRTY-LOCK*")
    ("DARTERFLY/JOURNAL" "*JOURNAL-LOCK*")
    ("DARTERFLY/DEVICES" "*VECTORS-LOCK*")
    ("DARTERFLY/DEVICES" "*INTERRUPTS-LOCK*")
    ("DARTERFLY/NET" "*TCP-LOCK*")))

(defstruct stop
  id
  thread
  condition
  text
  time
  (requests nil)
  (lock (sb-thread:make-mutex :name "stopped thread"))
  (changed (sb-thread:make-waitqueue)))

(defvar *stops* nil)
(defvar *stops-lock* (sb-thread:make-mutex :name "stopped threads"))
(defvar *next-stop* 0)

(defun system-locks-held ()
  (loop for (package name) in *system-locks*
        for symbol = (and (find-package package) (find-symbol name package))
        for lock = (and symbol (boundp symbol) (symbol-value symbol))
        when (and (typep lock 'sb-thread:mutex)
                  (eq (sb-thread:mutex-owner lock) sb-thread:*current-thread*))
          collect (sb-thread:mutex-name lock)))

(defun restart-description (restart)
  (format nil "~(~a~): ~a" (restart-name restart) restart))

(defun stopped ()
  (sb-thread:with-mutex (*stops-lock*)
    (loop for stop in (reverse *stops*)
          collect (list :id (stop-id stop)
                        :thread (sb-thread:thread-name (stop-thread stop))
                        :error (stop-text stop)
                        :restarts (mapcar #'restart-description
                                          (compute-restarts (stop-condition stop)))
                        :seconds (- (get-universal-time) (stop-time stop))))))

(defun find-stop (id)
  (sb-thread:with-mutex (*stops-lock*)
    (or (find id *stops* :key #'stop-id)
        (error "no stopped thread ~a" id))))

(defun ask-stopped (id request)
  (let ((stop (find-stop id))
        (answer (list :waiting)))
    (sb-thread:with-mutex ((stop-lock stop))
      (setf (stop-requests stop)
            (append (stop-requests stop) (list (cons request answer))))
      (sb-thread:condition-broadcast (stop-changed stop))
      (loop while (eq (first answer) :waiting)
            do (sb-thread:condition-wait (stop-changed stop) (stop-lock stop))))
    (destructuring-bind (how value) answer
      (if (eq how :error)
          (error "in the stopped thread: ~a" value)
          value))))

(defun stopped-backtrace (id &optional (count 30))
  (ask-stopped id (list :call (lambda ()
                                (with-output-to-string (s)
                                  (sb-debug:print-backtrace :stream s :count count))))))

(defun stopped-eval (id form)
  (ask-stopped id (list :call (lambda () (eval form)))))

(defun stopped-restart (id restart &rest values)
  (ask-stopped id (list :restart restart values)))

(defun answer (stop answer how value)
  (sb-thread:with-mutex ((stop-lock stop))
    (setf (first answer) how
          (rest answer) (list value))
    (sb-thread:condition-broadcast (stop-changed stop))))

(defun next-request (stop deadline)
  (sb-thread:with-mutex ((stop-lock stop))
    (loop until (or (stop-requests stop)
                    (> (get-internal-real-time) deadline))
          do (let ((left (/ (- deadline (get-internal-real-time))
                            internal-time-units-per-second)))
               (sb-thread:condition-wait (stop-changed stop) (stop-lock stop)
                                         :timeout (max 0.01 left))))
    (pop (stop-requests stop))))

(defun choose-restart (condition restart)
  (let ((restarts (compute-restarts condition)))
    (if (integerp restart)
        (nth restart restarts)
        (find restart restarts :key #'restart-name :test #'string-equal))))

(defun serve-stop (stop)
  (let ((deadline (+ (get-internal-real-time)
                     (* *keep-stopped-for* internal-time-units-per-second))))
    (loop
      (let ((request (next-request stop deadline)))
        (unless request
          (return))
        (destructuring-bind ((kind &rest args) . answer) request
          (ecase kind
            (:call
             (handler-case (answer stop answer :value (funcall (first args)))
               (error (e) (answer stop answer :error (princ-to-string e)))))
            (:restart
             (destructuring-bind (restart values) args
               (let ((chosen (choose-restart (stop-condition stop) restart)))
                 (if chosen
                     (progn
                       (answer stop answer :value (restart-name chosen))
                       (apply #'invoke-restart chosen values))
                     (answer stop answer :error (format nil "no restart ~a" restart))))))))))))

(defun stop-here (condition)
  (let ((stop (make-stop :id (sb-thread:with-mutex (*stops-lock*) (incf *next-stop*))
                         :thread sb-thread:*current-thread*
                         :condition condition
                         :text (or (ignore-errors (princ-to-string condition)) "?")
                         :time (get-universal-time))))
    (sb-thread:with-mutex (*stops-lock*)
      (push stop *stops*))
    (format *error-output* "~&stopped ~d: ~a: ~a~%  restarts: ~{~a~^; ~}~%  gives up in ~d s~%"
            (stop-id stop)
            (sb-thread:thread-name sb-thread:*current-thread*)
            (stop-text stop)
            (mapcar #'restart-description (compute-restarts condition))
            *keep-stopped-for*)
    (unwind-protect (serve-stop stop)
      (sb-thread:with-mutex (*stops-lock*)
        (setf *stops* (remove stop *stops*))))))
