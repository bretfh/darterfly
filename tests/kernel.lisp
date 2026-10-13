(in-package #:finch/test)

(def-suite kernel :in all)
(in-suite kernel)

(defun console-lines (out)
  (mapcar (lambda (line) (string-right-trim '(#\Return) line))
          (uiop:split-string out :separator '(#\Newline))))

(test finch-boots
  (image:image)
  (let ((lines (console-lines (image:check-boot))))
    (is (find "finch Kernel Version" lines :test #'search))
    (is (find "bsd_init: boot-args console=ttyS0 quiet halt" lines :test #'string=))
    (is (find "load_init_program: halt" lines :test #'string=))))

(test console-answers
  (let ((c (image:console)))
    (unwind-protect
         (progn
           (is (image:expect c "load_init_program: console"))
           (image:expect c "* ")
           (image:send c "(+ 1 2)")
           (is (search (format nil "~%3~%") (image:expect c "* ")))
           (image:send c "(software-type)")
           (is (search "\"Linux\"" (image:expect c "* ")))
           (image:send c "(finch/kernel:halt)"))
      (image:finish c))))
