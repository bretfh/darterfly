(defpackage #:finch/generation
  (:use #:cl)
  (:export #:resume #:contrib-steps #:core-steps #:*state*))
(in-package #:finch/generation)

(defvar *state* "/Users/finch/generation.state")

(defvar *kernel* "/System/Library/Kernels/kernel")

(defvar *run-core* "/System/Library/Kernels/finch.core")

(defvar *contrib-script* "/usr/src/finch/src/generation/contrib.lisp")

(defun state ()
  (when (probe-file *state*)
    (with-open-file (s *state*)
      (loop :for line := (read s nil s) :until (eq line s) :collect line))))

(defun note (&rest entry)
  (with-open-file (s *state* :direction :output :if-exists :append :if-does-not-exist :create)
    (with-standard-io-syntax (prin1 entry s) (terpri s)))
  (finch/vfs:vfs-sync))

(defun step-name (step) (first step))

(defun resume (steps)
  (let* ((state (state))
         (last (car (last state))))
    (when (eq (first last) :running)
      (let ((result (finch/run:collect)))
        (if (and result (eql 0 (getf result :exit)))
            (note :done (second last) result)
            (progn (note :failed (second last) result)
                   (return-from resume (list :failed (second last) result))))))
    (let ((done (loop :for (kind name) :in (state) :when (eq kind :done) :collect name)))
      (dolist (step steps (list :done (length done)))
        (unless (member (step-name step) done :test #'string=)
          (destructuring-bind (name kind thunk) step
            (ecase kind
              (:run (note :running name) (funcall thunk))
              (:lisp (let ((result (funcall thunk)))
                       (if result
                           (progn (note :done name result) (push name done))
                           (progn (note :failed name nil)
                                  (return-from resume (list :failed name)))))))))))))

(defun contrib-files (root)
  (append (list (pathname *contrib-script*))
          (mapcan (lambda (dir) (when (probe-file dir) (finch/run:tree-files dir)))
                  (list (concatenate 'string root "contrib/")
                        (concatenate 'string root "obj/sbcl-home/")
                        (concatenate 'string root "obj/from-self/")))))

(defun sbcl-run (root core cwd &rest args)
  (finch/run:run-core core (list* *kernel* "--core" *run-core* "--noinform" "--disable-debugger" "--no-sysinit" "--no-userinit" args)
                      :cwd (concatenate 'string root cwd) :files (contrib-files root)))

(defun asdf-step (root core name)
  (let ((fasl (format nil "~aobj/sbcl-home/contrib/~a.fasl" root name)))
    (list name :run
          (lambda ()
            (sbcl-run root core "contrib/asdf"
                      "--eval" (format nil "(setf sb-sys::*sbcl-homedir-pathname* #p~s)" (concatenate 'string root "obj/sbcl-home/"))
                      "--eval" "(setf (sb-ext:readtable-base-char-preference *readtable*) :both)"
                      "--eval" (format nil "(progn (ensure-directories-exist ~s) (compile-file #p\"SYS:CONTRIB;ASDF;~:@(~a~).LISP\" :print nil :output-file ~s))"
                                       fasl name fasl)
                      "--quit")))))

(defun contrib-step (root core name &rest requires)
  (let ((script *contrib-script*))
    (list name :run
          (lambda ()
            (apply #'sbcl-run root core (format nil "contrib/~a" name)
                   "--load" script name (mapcar (lambda (r) (format nil "~a.fasl" r)) requires))))))

(defun grovel-step (root name)
  (let ((dir (format nil "~aobj/from-self/contrib/~a/" root name)))
    (list (format nil "~a-grovel" name) :lisp
          (lambda ()
            (finch/cc:run-c (concatenate 'string dir "runme.c")
                            :args (list (concatenate 'string dir "generated-constants.lisp")))
            (probe-file (concatenate 'string dir "generated-constants.lisp"))))))

(defun contrib-steps (root &optional (core (concatenate 'string root "output/sbcl.core")))
  (list (asdf-step root core "uiop")
        (asdf-step root core "asdf")
        (contrib-step root core "sb-rotate-byte")
        (contrib-step root core "sb-md5" "sb-rotate-byte")
        (list "sb-posix-c" :run (third (contrib-step root core "sb-posix")))
        (grovel-step root "sb-posix")
        (contrib-step root core "sb-posix")
        (list "sb-bsd-sockets-c" :run (third (contrib-step root core "sb-bsd-sockets")))
        (grovel-step root "sb-bsd-sockets")
        (contrib-step root core "sb-bsd-sockets")))

(defun core-steps (root out &optional (core (concatenate 'string root "output/sbcl.core")))
  (list (list "finch.core" :run
              (lambda ()
                (finch/run:run-core
                 core
                 (list *kernel* "--core" *run-core* "--noinform" "--disable-debugger" "--no-sysinit" "--no-userinit"
                       "--eval" (format nil "(setf sb-sys::*sbcl-homedir-pathname* #p~s)" (concatenate 'string root "obj/sbcl-home/"))
                       "--eval" "(require :asdf)"
                       "--eval" "(asdf:initialize-source-registry '(:source-registry (:tree \"/usr/src/finch/\") (:tree \"/usr/share/common-lisp/sbcl/\") :ignore-inherited-configuration))"
                       "--eval" (format nil "(ensure-directories-exist ~s)" out)
                       "--load" "/usr/src/finch/src/image/finch-core.lisp" out)
                 :cwd "/Users/finch"
                 :files (append (finch/run:tree-files "/usr/src/finch/")
                                (finch/run:tree-files "/usr/share/common-lisp/sbcl/")
                                (finch/run:tree-files (concatenate 'string root "obj/sbcl-home/"))))))))
