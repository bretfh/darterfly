(in-package #:darterfly/test)

(def-suite worlds :in host)
(in-suite worlds)

(test a-rights-set-names-each-right-once
  (is (equal '(:console) (darterfly/worlds::rights-named (darterfly/worlds::rights-mask '(:console :console))))
      "naming a right twice grants it once, not the next bit up")
  (is (equal '(:console :worlds) (darterfly/worlds::rights-named (darterfly/worlds::rights-mask '(:worlds :console :worlds))))
      "order and repeats don't change the set")
  (is (= 0 (darterfly/worlds::rights-mask nil)) "no rights is the empty set")
  (signals error (darterfly/worlds::rights-mask '(:console :nonsense)) "an unknown right is refused, not ignored"))

(test a-hardware-check-counts-what-is-missing
  (let ((darterfly/image::*expected* '(:log :disk)))
    (is (darterfly/image::health-failures nil) "no answer at all is a failure")
    (is (darterfly/image::health-failures "garbled") "an answer that isn't rows is a failure")
    (is (find :disk (darterfly/image::health-failures '((:log :ok))) :key #'first)
        "an expected part with no row at all is a failure")
    (is (null (darterfly/image::health-failures '((:log :ok) (:disk :ok) (:audio :absent))))
        "every expected part ok, an unexpected one absent, is no failure")))

(test repeated-wakes-and-failed-suspends-are-distinguished
  (is (darterfly/image::suspend-succeeded-p "=> 1"))
  (is (darterfly/image::suspend-succeeded-p "=> 2"))
  (is (darterfly/image::suspend-succeeded-p "=> 11"))
  (dolist (reply '(nil "no answer" "=> NIL" "=> 0" "=> -1" "=> :failed"))
    (is (not (darterfly/image::suspend-succeeded-p reply)))))

(test a-lost-suspend-reply-still-records-the-machine-health
  (let ((darterfly/image::*expected* '(:log))
        (dir (merge-pathnames "lost-suspend-reply/" (scratch)))
        (settled nil))
    (sb-int:encapsulate 'darterfly/image::health-on-device 'lost-reply
      (lambda (&rest args) (declare (ignore args)) '((:log :ok))))
    (sb-int:encapsulate 'darterfly/image::device-eval 'lost-reply
      (lambda (&rest args) (declare (ignore args)) (error "transport failed after partial output => 1")))
    (sb-int:encapsulate 'darterfly/image::settle-health 'lost-reply
      (lambda (&rest args) (declare (ignore args)) (setf settled t) (values '((:log :ok)) 1 11)))
    (sb-int:encapsulate 'darterfly/image::results-dir 'lost-reply
      (lambda (&rest args) (declare (ignore args)) dir))
    (unwind-protect
         (let ((*standard-output* (make-string-output-stream)))
           (is (null (darterfly/image:hw "unused" :label "transport-loss")))
           (is (eq t settled) "a failed suspend RPC must still inspect the recovered machine")
           (let ((record (with-open-file (s (first (directory (merge-pathnames "*.sexp" dir)))) (read s))))
             (is (equal '((:log :ok)) (getf record :after)))
             (is (search "transport failed" (getf record :suspend-error)))))
      (dolist (name '(darterfly/image::health-on-device darterfly/image::device-eval
                      darterfly/image::settle-health darterfly/image::results-dir))
        (sb-int:unencapsulate name 'lost-reply))
      (uiop:delete-directory-tree dir :validate t :if-does-not-exist :ignore))))

(test worlds-have-distinct-window-owner-identities
  (let* ((parent mach:*task*)
         (port (mach:mach-port-allocate parent :receive))
         (a (bsd:make-world-proc "/" "Nyxt"))
         (b (bsd:make-world-proc "/" "Editor")))
    (unwind-protect
         (progn
           (is (not (eq parent (bsd:proc-task a))))
           (is (not (eq (bsd:proc-task a) (bsd:proc-task b))))
           (is (= (bsd:proc-pid a) (bsd:task-pid (bsd:proc-task a))))
           (is (= (bsd:proc-pid b) (bsd:task-pid (bsd:proc-task b))))
           (is (equal "Nyxt" (bsd::proc-comm a)))
           (bsd:end-world-proc a)
           (is (null (bsd:task-pid (bsd:proc-task a))))
           (is (= (bsd:proc-pid b) (bsd:task-pid (bsd:proc-task b))))
           (is (equal '(:receive) (mach:mach-port-type parent port))))
      (bsd:end-world-proc a)
      (bsd:end-world-proc b)
      (mach:mach-port-mod-refs parent port :receive -1))))

(test a-single-healthy-sample-is-not-a-settled-wake
  (let ((darterfly/image::*expected* '(:log))
        (dir (merge-pathnames "unsettled-wake/" (scratch))))
    (sb-int:encapsulate 'darterfly/image::health-on-device 'unsettled
      (lambda (&rest args) (declare (ignore args)) '((:log :ok))))
    (sb-int:encapsulate 'darterfly/image::device-eval 'unsettled
      (lambda (&rest args) (declare (ignore args)) "=> 1"))
    (sb-int:encapsulate 'darterfly/image::settle-health 'unsettled
      (lambda (&rest args) (declare (ignore args)) (values '((:log :ok)) 59 nil)))
    (sb-int:encapsulate 'darterfly/image::results-dir 'unsettled
      (lambda (&rest args) (declare (ignore args)) dir))
    (unwind-protect
         (let ((*standard-output* (make-string-output-stream)))
           (is (null (darterfly/image:hw "unused" :settle 60))))
      (dolist (name '(darterfly/image::health-on-device darterfly/image::device-eval
                      darterfly/image::settle-health darterfly/image::results-dir))
        (sb-int:unencapsulate name 'unsettled))
      (uiop:delete-directory-tree dir :validate t :if-does-not-exist :ignore))))
