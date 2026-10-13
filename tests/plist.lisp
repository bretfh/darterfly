(in-package #:finch/test)

(def-suite plist :in all)
(in-suite plist)

(defparameter +writer+ "
import plistlib, sys, datetime, os
out = sys.argv[1]
value = {
  'name': 'finch', 'count': 42, 'neg': -7, 'big': 2**63 + 5, 'pi': 3.25,
  'flag': True, 'off': False, 'when': datetime.datetime(2026, 10, 12, 22, 0, 0),
  'blob': bytes([0, 1]) + b'finch' + bytes([255]),
  'list': [1, 'two', [3.5, {}]],
  'unicode': 'nand\\u00fa \\U0001f426 & <mixed>', 'empty': '',
  'nested': {'a': {'b': []}},
  'long': 'x' * 40,
}
for fmt, name in ((plistlib.FMT_XML, 'v.xml'), (plistlib.FMT_BINARY, 'v.bin')):
    with open(os.path.join(out, name), 'wb') as f:
        plistlib.dump(value, f, fmt=fmt, sort_keys=False)
with open(os.path.join(out, 'uid.bin'), 'wb') as f:
    plistlib.dump({'$top': {'root': plistlib.UID(5)}, 'many': [plistlib.UID(300)]}, f,
                  fmt=plistlib.FMT_BINARY)
")

(defvar *plists* nil)

(defun plists ()
  (or *plists*
      (let ((dir (scratch)))
        (with-open-file (s (merge-pathnames "write.py" dir) :direction :output
                                                            :if-exists :supersede)
          (write-string +writer+ s))
        (sh "python3" "-I" (uiop:native-namestring (merge-pathnames "write.py" dir))
            (uiop:native-namestring dir))
        (setf *plists* dir))))

(defun fixture (name)
  (merge-pathnames name (plists)))

(defun key (h k)
  (multiple-value-bind (v found) (gethash k h)
    (is-true found "missing key ~s" k)
    v))

(defun check-value (h)
  (is (= 14 (hash-table-count h)))
  (is (string= "finch" (key h "name")))
  (is (= 42 (key h "count")))
  (is (= -7 (key h "neg")))
  (is (= (+ (expt 2 63) 5) (key h "big")))
  (is (= 3.25d0 (key h "pi")))
  (is (eq t (key h "flag")))
  (is (null (key h "off")))
  (is (= (encode-universal-time 0 0 22 12 10 2026 0)
         (plist:date-universal-time (key h "when"))))
  (is (equalp #(0 1 102 105 110 99 104 255) (key h "blob")))
  (is (typep (key h "blob") '(vector (unsigned-byte 8))))
  (let ((list (key h "list")))
    (is (= 1 (aref list 0)))
    (is (string= "two" (aref list 1)))
    (is (= 3.5d0 (aref (aref list 2) 0)))
    (is (zerop (hash-table-count (aref (aref list 2) 1)))))
  (is (string= (format nil "nand~c ~c & <mixed>" (code-char #xfa) (code-char #x1f426))
               (key h "unicode")))
  (is (string= "" (key h "empty")))
  (is (string= (make-string 40 :initial-element #\x) (key h "long")))
  (is (equalp #() (gethash "b" (gethash "a" (key h "nested"))))))

(test xml
  (check-value (plist:read-plist (fixture "v.xml"))))

(test binary
  (check-value (plist:read-plist (fixture "v.bin"))))

(test uids
  (let ((h (plist:read-plist (fixture "uid.bin"))))
    (is (= 5 (plist:uid-value (gethash "root" (gethash "$top" h)))))
    (is (= 300 (plist:uid-value (aref (gethash "many" h) 0))))))

(test not-a-plist
  (signals plist:plist-error
    (plist:read-plist (map '(vector (unsigned-byte 8)) #'char-code "<html></html>"))))
