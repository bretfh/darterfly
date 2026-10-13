(require :asdf)

(defparameter +mine+ '(:finch/mach :finch/plist :finch/macho :finch/dyld :finch/objc :finch/mig :finch/server :finch/ca :finch/bsd :finch/xpc :finch/launchd :finch/shell :finch/kernel :finch/image :finch/qmp :finch/io :finch/text :finch/imageio :finch/windowserver :finch/apps :finch/tahoe :finch))

(defvar *warnings* nil)

(defun minep (condition)
  (let ((*package* (find-package :cl-user))
        (*print-pretty* nil))
    (and (not (typep condition 'sb-kernel:redefinition-warning))
         (search "FINCH" (princ-to-string condition))
         t)))

(handler-bind ((warning (lambda (c)
                          (when (minep c)
                            (push (list (type-of c) (princ-to-string c)) *warnings*)))))
  (asdf:load-system :finch :force +mine+)
  (asdf:load-system :finch/tahoe :force +mine+))

(let ((warnings (reverse *warnings*)))
  (cond ((null warnings)
         (princ :loaded)
         (terpri)
         (sb-ext:exit :code 0))
        (t
         (format t "~&~d warning~:p from finch's own code:~%" (length warnings))
         (loop :for (kind text) :in warnings
               :do (format t "  ~(~a~): ~a~%" kind text))
         (finish-output)
         (sb-ext:exit :code 1))))
