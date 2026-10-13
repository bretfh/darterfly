(in-package #:finch/server)

(defparameter *event-fields*
  '((0 . :mouse-event-number) (1 . :mouse-event-click-state) (2 . :mouse-event-pressure)
    (3 . :mouse-event-button-number) (4 . :mouse-event-delta-x) (5 . :mouse-event-delta-y)
    (6 . :mouse-event-instant-mouser) (7 . :mouse-event-sub-type)
    (8 . :keyboard-event-autorepeat) (9 . :keyboard-event-keycode) (10 . :keyboard-event-keyboard-type)
    (39 . :event-target-process-serial-number) (40 . :event-target-unix-process-id)
    (41 . :event-source-unix-process-id) (42 . :event-source-user-data) (43 . :event-source-user-id)
    (44 . :event-source-group-id) (45 . :event-source-state-id)
    (55 . :type) (56 . :location) (58 . :timestamp) (59 . :flags)))

(defparameter *event-types*
  '((1 . :left-mouse-down) (2 . :left-mouse-up) (3 . :right-mouse-down) (4 . :right-mouse-up)
    (5 . :mouse-moved) (6 . :left-mouse-dragged) (10 . :key-down) (11 . :key-up) (12 . :flags-changed)))

(defun field-name (n) (or (cdr (assoc n *event-fields*)) n))
(defun field-number (name) (if (integerp name) name (car (rassoc name *event-fields*))))

(defun take-be (r n)
  (loop :with v := 0 :repeat n :do (setf v (logior (ash v 8) (take-byte r))) :finally (return v)))

(defun put-be (w n v)
  (loop :for i :from (1- n) :downto 0 :do (vector-push-extend (ldb (byte 8 (* 8 i)) v) w)))

(defun decode-event (octets)
  (let ((r (reader (coerce octets '(simple-array (unsigned-byte 8) (*))))))
    (let ((header (take-be r 4)))
      (list* :header header
             (loop :while (< (reader-at r) (length (reader-octets r)))
                   :append (let* ((count (take-be r 2))
                                  (word (take-be r 2))
                                  (kind (ldb (byte 2 14) word))
                                  (field (ldb (byte 14 0) word))
                                  (values (loop :repeat count
                                                :collect (ecase kind
                                                           (0 (take-be r 8))
                                                           (1 (let ((v (take-be r 4))) (if (logbitp 31 v) (- v (ash 1 32)) v)))
                                                           (3 (sb-kernel:make-single-float
                                                               (let ((v (take-be r 4))) (if (logbitp 31 v) (- v (ash 1 32)) v))))))))
                             (list (field-name field) (cons kind values))))))))

(defun encode-event (event)
  (let ((w (make-array 0 :element-type '(unsigned-byte 8) :adjustable t :fill-pointer 0)))
    (put-be w 4 (getf event :header))
    (loop :for (name (kind . values)) :on (cddr event) :by #'cddr
          :do (put-be w 2 (length values))
              (put-be w 2 (logior (ash kind 14) (field-number name)))
              (dolist (v values)
                (ecase kind
                  (0 (put-be w 8 (ldb (byte 64 0) v)))
                  (1 (put-be w 4 (ldb (byte 32 0) v)))
                  (3 (put-be w 4 (ldb (byte 32 0) (sb-kernel:single-float-bits v)))))))
    (coerce w '(simple-array (unsigned-byte 8) (*)))))

(defun event-value (event name)
  (second (getf (cddr event) name)))

(defun event-type (event)
  (let ((n (event-value event :type)))
    (or (cdr (assoc n *event-types*)) n)))

(defun event-character (event)
  (let ((code (event-value event 77)))
    (and code (plusp code) (code-char code))))

(defun key-event (down keycode character &key (timestamp 0) (location '(0.0 0.0)))
  (list :header 2
        53 '(1 0) 54 '(1 0) :type (list 1 (if down 10 11))
        :location (list* 3 location) 57 '(3 0.0 0.0) :timestamp (list 0 timestamp)
        :flags '(1 #x20000100) 51 '(1 0) 52 '(1 0) 169 (list 0 timestamp) 106 '(1 0) 107 '(1 0)
        :keyboard-event-keycode (list 1 keycode) :keyboard-event-autorepeat '(1 0)
        :keyboard-event-keyboard-type '(1 3) 76 '(1 252)
        77 (list 1 (char-code character)) 78 (list 1 (char-code character))
        79 '(1 0) 80 '(1 26) 81 '(1 0) 127 '(1 0) 128 '(1 0) 82 (list 1 (char-code character))))

(defun mouse-event (type x y &key (timestamp 0) (window 0) (wx 0.0) (wy 0.0) (clicks 1))
  (list :header 2
        53 '(1 0) 54 '(1 0) :type (list 1 (car (rassoc type *event-types*)))
        :location (list 3 (float x 1.0) (float y 1.0)) 57 (list 3 (float wx 1.0) (float wy 1.0))
        :timestamp (list 0 timestamp) :flags '(1 256) 51 '(1 0) 52 '(1 0) 169 (list 0 timestamp)
        106 '(1 0) 107 '(1 0) :mouse-event-sub-type '(1 0) :mouse-event-number '(1 0)
        :mouse-event-click-state (list 1 clicks) :mouse-event-pressure (list 1 (if (member type '(:left-mouse-down)) 255 0))
        :mouse-event-button-number '(1 0) :mouse-event-delta-x '(1 0) :mouse-event-delta-y '(1 0)
        :mouse-event-instant-mouser '(1 0) 89 '(1 0) 90 '(1 0) 91 (list 1 window) 92 '(1 0)
        108 '(1 1) 60 '(1 0) 61 '(0 0) 62 '(0 0) 63 '(1 0)))

(defun event-location (event)
  (cdr (getf (cddr event) :location)))

(defun event-window-location (event)
  (cdr (getf (cddr event) 57)))
