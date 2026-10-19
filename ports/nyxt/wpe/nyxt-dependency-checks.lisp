(in-package #:cl-user)
;; Exercise the actual upstream Lisp wrappers, not just the C entry points.
(multiple-value-bind (status output errors)
    (iolib/os:run-program '("/usr/bin/pkg-config" "--modversion" "libfixposix"))
  (assert (eql status 0))
  (assert (equal output (format nil "0.4.3~%")))
  (assert (zerop (length errors))))
(format t "~&[NYXT IOLIB PROCESS PASS]~%")
(finish-output)
(asdf:load-system :sqlite)
(let ((db (sqlite:connect ":memory:")))
  (unwind-protect
       (progn
         (sqlite:execute-non-query db
           "CREATE TABLE visits (id INTEGER PRIMARY KEY, url TEXT NOT NULL)")
         (sqlite:execute-non-query db
           "INSERT INTO visits (url) VALUES (?)" "https://darterfly.test/")
         (assert (equal "https://darterfly.test/"
                   (sqlite:execute-single db "SELECT url FROM visits WHERE id=1")))
         (sqlite:execute-non-query db "BEGIN")
         (sqlite:execute-non-query db "DELETE FROM visits")
         (sqlite:execute-non-query db "ROLLBACK")
         (assert (= 1 (sqlite:execute-single db "SELECT COUNT(*) FROM visits"))))
    (sqlite:disconnect db)))
(format t "~&[NYXT SQLITE MEMORY PASS]~%")
(finish-output)
