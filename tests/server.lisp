(in-package #:finch/test)

(def-suite server :in all)
(in-suite server)

(defun hex-octets (words)
  (map '(simple-array (unsigned-byte 8) (*)) (lambda (w) (parse-integer w :radix 16)) words))

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

(test transactions-round-trip
  (loop :for (name . forms) :in +transactions+
        :do (is (equalp forms (server:decode-transaction (server:encode-transaction forms))) "~a round-trips" name)))

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

(test events-round-trip
  (let* ((a (server:decode-event (server:encode-event (server:key-event t 0 #\a :timestamp 1234567 :location '(10.0 10.0)))))
         (ret (server:decode-event (server:encode-event (server:key-event t #x24 #\Return :timestamp 1 :location '(0.0 0.0)))))
         (down (server:decode-event (server:encode-event (server:mouse-event :left-mouse-down 300 145 :timestamp 1234567)))))
    (is (eq :key-down (server:event-type a)))
    (is (eql #\a (server:event-character a)))
    (is (= 1234567 (server:event-value a :timestamp)))
    (is (= #x24 (server:event-value ret :keyboard-event-keycode)))
    (is (eql #\Return (server:event-character ret)))
    (is (eq :left-mouse-down (server:event-type down)))
    (is (equal '(300.0 145.0) (cdr (getf (cddr down) :location))))))

(test regions-round-trip
  (let ((empty (hex-octets '("00" "00" "00" "80" "02" "00" "00" "00" "ff" "ff" "ff" "7f")))
        (rect (hex-octets '("00" "00" "00" "80" "02" "00" "00" "00" "00" "00" "00" "00" "04" "00" "00" "00"
                            "00" "00" "00" "00" "80" "02" "00" "00" "e0" "01" "00" "00" "02" "00" "00" "00"
                            "ff" "ff" "ff" "7f"))))
    (is (equalp empty (server:rect-region 0 0 0 0)))
    (is (equalp rect (server:rect-region 0 0 640 480)))
    (is (equal '(0 0 640 480) (server:region-bounds rect)))
    (is (equal '(100 50 300 200) (server:region-bounds (server:rect-region 100 50 300 200))))
    (is (equalp rect (server:bands-octets (server:region-bands rect))))))
