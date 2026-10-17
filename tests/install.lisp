(in-package #:darterfly/test)

(def-suite install :in all)
(in-suite install)

(defstruct reload-probe a b)
(defclass reload-class () ())
(defconstant +reload-constant+ 3)

(defun hazards-of (text)
  (let ((file (merge-pathnames "reload-probe.lisp" (scratch))))
    (with-open-file (s file :direction :output :if-exists :supersede)
      (write-string "(in-package #:darterfly/test)" s) (terpri s) (write-string text s))
    (darterfly/install::reload-hazards (list (namestring file)))))

(test reloading-only-safe-definitions-is-allowed
  (is (null (hazards-of "(defstruct reload-probe a b) (defclass reload-class () ((x))) (defconstant +reload-constant+ 3) (defun f () 1)")))
  (is (null (hazards-of "(defstruct brand-new-struct x) (defconstant +brand-new-constant+ 9)"))))

(test reload-hazards-are-caught-before-loading
  (is (search "changes its slots" (first (hazards-of "(defstruct reload-probe a b c)"))))
  (is (search "a class can't take its name" (first (hazards-of "(defclass reload-probe () ())"))))
  (is (search "a struct can't take its name" (first (hazards-of "(defstruct reload-class x)"))))
  (is (search "changes from 3 to 4" (first (hazards-of "(defconstant +reload-constant+ 4)")))))

(test forms-typed-since-the-last-save-are-kept-and-replayable
  (let ((darterfly/journal:*journal* (namestring (merge-pathnames "forms" (scratch)))))
    (uiop:delete-file-if-exists darterfly/journal:*journal*)
    (darterfly/journal:note-form "(defvar cl-user::*journal-a* 1)" :origin :listener)
    (darterfly/journal:note-save)
    (darterfly/journal:note-form "(defvar cl-user::*journal-b* 2) (defvar cl-user::*journal-c* (+ cl-user::*journal-b* 1))" :origin :nrepl)
    (darterfly/journal:note-form "(error \"boom\")" :origin :listener)
    (let ((since (darterfly/journal:forms-since-save)))
      (is (= 2 (length since)) "only what came after the save")
      (let ((results (darterfly/journal:replay since)))
        (is (eq :ok (third (first results))))
        (is (= 3 (symbol-value 'cl-user::*journal-c*)))
        (is (eq :error (first (third (second results)))) "a failing form is reported, not fatal")))))

(test an-installed-save-trims-the-journal-to-what-came-after-it
  (let ((darterfly/journal:*journal* (namestring (merge-pathnames "forms-trim" (scratch)))))
    (uiop:delete-file-if-exists darterfly/journal:*journal*)
    (darterfly/journal:note-form "(+ 1 1)")
    (darterfly/journal:note-save)
    (darterfly/journal:note-form "(+ 2 2)")
    (is (= 1 (darterfly/journal:trim)))
    (is (equal '("(+ 2 2)") (mapcar #'fifth (darterfly/journal:forms-since-save))))))

(test a-runtime-without-the-heap-check-does-not-block-saving
  (is (null (darterfly/install:heap-errors)) "the host runtime has no check, and says so with nil instead of an error"))
