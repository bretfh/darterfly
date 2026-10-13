(in-package #:finch/io)

(defparameter +keymap+
  '((1 #\Esc) (2 #\1 #\!) (3 #\2 #\@) (4 #\3 #\#) (5 #\4 #\$) (6 #\5 #\%) (7 #\6 #\^) (8 #\7 #\&)
    (9 #\8 #\*) (10 #\9 #\() (11 #\0 #\)) (12 #\- #\_) (13 #\= #\+) (14 #\Backspace) (15 #\Tab)
    (16 #\q #\Q) (17 #\w #\W) (18 #\e #\E) (19 #\r #\R) (20 #\t #\T) (21 #\y #\Y) (22 #\u #\U)
    (23 #\i #\I) (24 #\o #\O) (25 #\p #\P) (26 #\[ #\{) (27 #\] #\}) (28 #\Return)
    (30 #\a #\A) (31 #\s #\S) (32 #\d #\D) (33 #\f #\F) (34 #\g #\G) (35 #\h #\H) (36 #\j #\J)
    (37 #\k #\K) (38 #\l #\L) (39 #\; #\:) (40 #\' #\") (41 #\` #\~) (43 #\\ #\|)
    (44 #\z #\Z) (45 #\x #\X) (46 #\c #\C) (47 #\v #\V) (48 #\b #\B) (49 #\n #\N) (50 #\m #\M)
    (51 #\, #\<) (52 #\. #\>) (53 #\/ #\?) (57 #\Space)))

(defconstant +key-leftshift+ 42)
(defconstant +key-rightshift+ 54)

(defun key-character (code shift)
  (let ((entry (assoc code +keymap+)))
    (and entry (if (and shift (third entry)) (third entry) (second entry)))))

(defun shift-key-p (code)
  (member code (list +key-leftshift+ +key-rightshift+)))

(defparameter +virtual-keycodes+
  '((30 . 0) (31 . 1) (32 . 2) (33 . 3) (35 . 4) (34 . 5) (44 . 6) (45 . 7) (46 . 8) (47 . 9)
    (48 . 11) (16 . 12) (17 . 13) (18 . 14) (19 . 15) (21 . 16) (20 . 17) (2 . 18) (3 . 19)
    (4 . 20) (5 . 21) (7 . 22) (6 . 23) (13 . 24) (10 . 25) (8 . 26) (12 . 27) (9 . 28)
    (11 . 29) (27 . 30) (24 . 31) (22 . 32) (26 . 33) (23 . 34) (25 . 35) (28 . 36) (38 . 37)
    (36 . 38) (40 . 39) (37 . 40) (39 . 41) (43 . 42) (51 . 43) (53 . 44) (49 . 45) (50 . 46)
    (52 . 47) (15 . 48) (57 . 49) (41 . 50) (14 . 51) (1 . 53)))

(defun virtual-keycode (code)
  (cdr (assoc code +virtual-keycodes+)))
