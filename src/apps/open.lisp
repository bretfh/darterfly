(in-package #:darterfly/apps)

(defparameter *in-own-world* '("Hello" "Terminal" "Editor"))

(defparameter *app-memory* 512)

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

(defun world-job (path)
  (list :label (fresh-label (program-name path))
        :world (list :core "/System/Library/Kernels/darterfly.core"
                     :memory *app-memory*
                     :evals (list (format nil "(progn (darterfly/bsd:wait4 (darterfly/bsd:posix-spawn ~s (list ~s) nil)) (sb-ext:exit))"
                                          path path)))
        :run-at-load t))

(defun open-application (path)
  (if (member (program-name path) *in-own-world* :test #'string=)
      (darterfly/init:submit (world-job path))
      (bsd:posix-spawn path (list path) nil)))
