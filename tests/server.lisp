(in-package #:darterfly/test)

(def-suite server :in host)
(in-suite server)

(test events-carry-what-apps-read
  (let ((a (server:key-event t 30 #\a :timestamp 1234567 :location '(10 10)))
        (down (server:mouse-event :left-mouse-down 300 145 :wx 20 :wy 30 :clicks 2)))
    (is (eq :key-down (server:event-type a)))
    (is (eql #\a (server:event-character a)))
    (is (= 30 (server:event-value a :keycode)))
    (is (= 1234567 (server:event-value a :timestamp)))
    (is (eq :key-up (server:event-type (server:key-event nil 30 #\a))))
    (is (eq :left-mouse-down (server:event-type down)))
    (is (equal '(300 145) (server:event-location down)))
    (is (equal '(20 30) (server:event-window-location down)))
    (is (= 2 (server:event-value down :clicks)))))
