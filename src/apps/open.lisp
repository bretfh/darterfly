(in-package #:darterfly/apps)

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

(defun world-job (path world)
  (list :label (fresh-label (program-name path))
        :world (list* :core (getf world :core "/System/Library/Kernels/darterfly.core")
                      :evals (list (format nil "(progn (darterfly/bsd:wait4 (darterfly/bsd:posix-spawn ~s (list ~s) nil)) (sb-ext:exit))"
                                           path path))
                      (loop :for (key value) :on world :by #'cddr
                            :unless (member key '(:core :evals))
                              :append (list key value)))
        :run-at-load t))

(defun open-application (path &key world)
  (if world
      (darterfly/init:submit (world-job path world))
      (bsd:posix-spawn path (list path) nil)))
