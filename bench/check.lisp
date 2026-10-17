(require :asdf)

(defparameter +mine+ '(:darterfly/mach :darterfly/server :darterfly/layer :darterfly/bsd :darterfly/init :darterfly/shell :darterfly/kernel :darterfly/image :darterfly/qmp :darterfly/io :darterfly/text :darterfly/imageio :darterfly/kit :darterfly/windowserver :darterfly/apps :darterfly))

(defvar *warnings* nil)

(defun minep (condition)
  (let ((*package* (find-package :cl-user))
        (*print-pretty* nil))
    (and (not (typep condition 'sb-kernel:redefinition-warning))
         (search "DARTERFLY" (princ-to-string condition))
         t)))

(handler-bind ((warning (lambda (c)
                          (when (minep c)
                            (push (list (type-of c) (princ-to-string c)) *warnings*)))))
  (asdf:load-system :darterfly :force +mine+))

(let ((warnings (reverse *warnings*)))
  (cond ((null warnings)
         (princ :loaded)
         (terpri)
         (sb-ext:exit :code 0))
        (t
         (format t "~&~d warning~:p from darterfly's own code:~%" (length warnings))
         (loop :for (kind text) :in warnings
               :do (format t "  ~(~a~): ~a~%" kind text))
         (finish-output)
         (sb-ext:exit :code 1))))
