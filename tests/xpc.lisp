(in-package #:finch/test)

(def-suite xpc :in all)
(in-suite xpc)

(test xpc-double-round-trips
  (dolist (d (list 0.1d0 -2.5d0 1d300 pi))
    (is (equal (list :double d) (xpc:decode (xpc:encode (list :double d)))))))
