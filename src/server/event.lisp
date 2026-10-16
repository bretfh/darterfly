(defpackage #:finch/server
  (:use #:cl)
  (:export #:key-event #:mouse-event #:event-type #:event-value #:event-character
           #:event-location #:event-window-location))
(in-package #:finch/server)

(defun key-event (down keycode character &key (timestamp 0) (location '(0 0)))
  (list :type (if down :key-down :key-up) :keycode keycode :character character
        :timestamp timestamp :location location))

(defun mouse-event (type x y &key (timestamp 0) (window 0) (wx 0) (wy 0) (clicks 1))
  (list :type type :location (list x y) :window window :window-location (list wx wy)
        :clicks clicks :timestamp timestamp))

(defun event-type (event) (getf event :type))
(defun event-value (event name) (getf event name))
(defun event-character (event) (getf event :character))
(defun event-location (event) (getf event :location))
(defun event-window-location (event) (getf event :window-location))
