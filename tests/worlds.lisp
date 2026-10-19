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
