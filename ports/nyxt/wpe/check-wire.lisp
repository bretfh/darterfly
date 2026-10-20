(require :asdf)
(asdf:load-system :darterfly/test)
(load "ports/nyxt/wpe/nyxt-wire.lisp")
(in-package #:darterfly/nyxt-wire)
(let ((original (symbol-function 'raw-io))
      (original-wait (symbol-function 'wait-ready)) (*io-timeout* .1)
      (c (make-connection :fd 0 :root t)))
  (unwind-protect
      (progn
        ;; A packet spanning multiple idle periods is valid while progressing.
        (setf (symbol-function 'raw-io)
              (lambda (&rest args) (declare (ignore args)) (sleep .02) 1))
        (assert (= 12 (length (transfer c (make-array 12) t (deadline)))))
        ;; The absolute bound still rejects an indefinitely trickling peer.
        (assert (handler-case
                    (progn (transfer c (make-array 128) t (deadline)) nil)
                  (error () t)))
        (setf (symbol-function 'wait-ready)
              (lambda (&rest args) (declare (ignore args)) (sleep .005)))
        (setf (symbol-function 'raw-io)
              (lambda (&rest args) (declare (ignore args)) (values -1 11)))
        (assert (handler-case
                    (progn (transfer c (make-array 1) t (deadline)) nil)
                  (error () t)))
        ;; Header/body transitions retain the same absolute packet deadline.
        (setf (symbol-function 'raw-io)
              (lambda (connection vector start end writep)
                (declare (ignore connection vector start writep)) end))
        (multiple-value-bind (data idle absolute)
            (transfer c (make-array 1) t (deadline))
          (declare (ignore data))
          (assert absolute)
          (assert (eql absolute
            (nth-value 2 (transfer c (make-array 1) t idle absolute)))))
        (format t "~&[NYXT WIRE PROGRESS AND DEADLINES PASS]~%"))
    (setf (symbol-function 'raw-io) original
          (symbol-function 'wait-ready) original-wait)))
