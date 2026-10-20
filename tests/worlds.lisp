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
