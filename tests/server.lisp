(in-package #:finch/test)

(def-suite server :in all)
(in-suite server)

(defun hex-octets (words)
  (map '(simple-array (unsigned-byte 8) (*)) (lambda (w) (parse-integer w :radix 16)) words))

(defun oracle-transactions ()
  (with-open-file (s (asdf:system-relative-pathname :finch "tests/transactions.txt"))
    (loop :for line := (read-line s nil)
          :while line
          :for words := (uiop:split-string line :separator " ")
          :collect (cons (first words) (hex-octets (rest words))))))

(defparameter +transactions+
  '(("order-above" ("OrderWindow" #x3c 1 0))
    ("order-below" ("OrderWindow" #x1234 -1 #x3d))
    ("order-group-out" ("OrderWindowGroup" #x3c 0 0))
    ("level" ("SetWindowLevel" #x3c -2147483623))
    ("sub-level" ("SetWindowSubLevel" #x3c -1))
    ("move" ("MoveWindowWithGroup" #x3c 100d0 -20d0))
    ("move-fraction" ("MoveWindowWithGroup" #x3c 10.5d0 0.25d0))
    ("alpha" ("SetWindowAlpha" #x3c 0.5 0.0))
    ("resolution" ("SetWindowResolution" #x3c 2d0))
    ("space" ("AddWindowToSpace" #x3c #x100000001))
    ("property" ("SetWindowProperty" #x3c "finch" "bird"))
    ("property-bool" ("SetWindowProperty" #x3c "on" :true))
    ("property-null" ("SetWindowProperty" #x3c "gone" nil))
    ("two" ("ResetWindow" #x3c) ("OrderWindow" #x3c 2 0))))

(test transactions-match-skylight
  (let ((oracle (oracle-transactions)))
    (is (= 15 (length oracle)))
    (loop :for (name . forms) :in +transactions+
          :for octets := (cdr (assoc name oracle :test #'string=))
          :do (is (equalp forms (server:decode-transaction octets)) "~a decodes" name)
              (is (equalp octets (server:encode-transaction forms)) "~a encodes" name))
    (let* ((octets (cdr (assoc "shape" oracle :test #'string=)))
           (forms (server:decode-transaction octets)))
      (is (equal "SetWindowShape" (first (first forms))))
      (is (= 36 (length (third (first forms)))))
      (is (equalp octets (server:encode-transaction forms))))))

(test packed-integers-round-trip
  (dolist (n (list 0 1 -1 127 128 -128 -129 255 256 #xffff #x7fffffff (- (expt 2 31)) (1- (expt 2 63)) (- (expt 2 63))))
    (let ((form (list "SetClientAdvisory" n)))
      (is (= (ldb (byte 64 0) n)
             (second (first (server:decode-transaction (server:encode-transaction (list form))))))))))

(test transaction-stops-at-the-end-and-at-bad-ops
  (is (equalp '(("ResetWindow" 1)) (server:decode-transaction #(#x17 #x10 1 #xff #x17 #x10 2))))
  (signals server:transaction-error (server:decode-transaction #(#x56)))
  (signals server:transaction-error (server:decode-transaction #(#x17)))
  (signals server:transaction-error (server:encode-transaction '(("ResetWindow")))))
