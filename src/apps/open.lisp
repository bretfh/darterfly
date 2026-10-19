(in-package #:darterfly/apps)

(defparameter *in-own-world* '("Hello" "Terminal" "Editor" "Nyxt"))

(defparameter *app-memory* 512)
;; Explicit per-app budgets; keep the existing lightweight app default.
(defparameter *single-instance-apps* '("Nyxt"))
(defparameter *app-memory-overrides* '(("Nyxt" . 2048)))

(defun program-name (path)
  (subseq path (1+ (or (position #\/ path :from-end t) -1))))

(defun active-label-p (label)
  (find-if (lambda (job)
             (and (equal (getf job :label) label)
                  (member (getf job :state) '(:starting :running :restarting :quarantined))))
           (darterfly/init:jobs)))

(defun fresh-label (name)
  (loop :for n :from 1
        :for label := (if (= n 1) name (format nil "~a ~d" name n))
        :unless (active-label-p label)
          :return label))

(defun world-job (path &optional (argv (list path)))
  (list :label (if (member (program-name path) *single-instance-apps* :test #'equal)
                   (program-name path) (fresh-label (program-name path)))
        :world (list :core "/System/Library/Kernels/darterfly.core"
                     :memory (or (cdr (assoc (program-name path) *app-memory-overrides*
                                              :test #'equal)) *app-memory*)
                     :evals (list (format nil "(progn (let ((status (nth-value 1 (darterfly/bsd:wait4 (darterfly/bsd:posix-spawn ~s (quote ~s) nil))))) (sb-ext:exit :code (if (and status (darterfly/bsd:wifexited status)) (darterfly/bsd:wexitstatus status) 1))))"
                                          path argv)))
        :run-at-load t))

(defun activate-application (name argv)
  (let ((world (darterfly/run:find-world name)))
    (when world
      ;; A second click during startup must not create a competing engine.
      ;; Activation is optional until the installed application is loaded.
      (darterfly/run:world-eval world
        (format nil "(let* ((p (find-package ~s)) (f (and p (find-symbol ~s p)))) (when (and f (fboundp f)) (funcall f (quote ~s))))"
          (format nil "DARTERFLY/~a-APPLICATION" (string-upcase name)) "ACTIVATE" (rest argv)) :timeout 5)))
  name)

(defun open-application (path &optional (argv (list path)))
  (let ((name (program-name path)))
    (cond ((and (member name *single-instance-apps* :test #'equal)
                (active-label-p name))
           (activate-application name argv))
          ((member name *in-own-world* :test #'string=)
           (darterfly/init:submit (world-job path argv)))
          (t (bsd:posix-spawn path argv nil)))))
