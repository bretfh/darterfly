(in-package #:darterfly/kit)

(export '(command register-command unregister-command find-command available-commands
          command-id command-label command-enabled-p invoke-command read-command))

(defstruct (command (:constructor %make-command)) id label action enabled keys)
(bsd:define-process-variable *commands* nil)

(defun register-command (id label action &key (enabled (constantly t)) keys)
  "Register an application-local operation. ACTION takes the invoking window."
  (let ((command (%make-command :id id :label label :action action :enabled enabled :keys keys)))
    (setf *commands* (cons command (remove id *commands* :key #'command-id :test #'equal)))
    command))
(defun unregister-command (id)
  (setf *commands* (remove id *commands* :key #'command-id :test #'equal)))
(defun find-command (id) (find id *commands* :key #'command-id :test #'equal))
(defun command-enabled-p (command &optional (window (front-window)))
  (and command (funcall (command-enabled command) window)))
(defun available-commands (&optional (window (front-window)))
  (remove-if-not (lambda (command) (command-enabled-p command window)) (reverse *commands*)))
(defun invoke-command (id &optional (window (front-window)))
  (let ((command (find-command id)))
    (cond ((null command) :unknown)
          ((not (command-enabled-p command window)) :disabled)
          (t (funcall (command-action command) window)))))
(defun command-key (window key modifiers)
  (let ((command (find-if (lambda (command)
                            (some (lambda (chord)
                                    (and (= key (first chord))
                                         (equal (sort (copy-list modifiers) #'string<)
                                                (sort (copy-list (rest chord)) #'string<))))
                                  (command-keys command))) *commands*)))
    (when command (invoke-command (command-id command) window) t)))

(defun ensure-standard-commands ()
  (unless (find-command :switch-window)
    (register-command :switch-window "Switch to a window…"
                      (lambda (window) (declare (ignore window)) (read-window))
                      :keys '((41 :meta)))
    (register-command :commands "Run a command…"
                      (lambda (window) (read-command :window window)) :keys '((45 :alt) (25 :meta :shift)))
    (register-command :minimize "Minimize window"
                      (lambda (window) (minimize-window window))
                      :enabled (lambda (window) (and window (eq :titled (style window))))
                      :keys '((50 :meta)))
    (register-command :close-window "Close window"
                      (lambda (window) (close-window window))
                      :enabled (lambda (window) (and window (eq :titled (style window)))))))
