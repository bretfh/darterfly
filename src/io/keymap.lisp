(in-package #:finch/io)

(defparameter +keymap+
  '((1 #\Esc) (2 #\1 #\!) (3 #\2 #\@) (4 #\3 #\#) (5 #\4 #\$) (6 #\5 #\%) (7 #\6 #\^) (8 #\7 #\&)
    (9 #\8 #\*) (10 #\9 #\() (11 #\0 #\)) (12 #\- #\_) (13 #\= #\+) (14 #\Backspace) (15 #\Tab)
    (16 #\q #\Q) (17 #\w #\W) (18 #\e #\E) (19 #\r #\R) (20 #\t #\T) (21 #\y #\Y) (22 #\u #\U)
    (23 #\i #\I) (24 #\o #\O) (25 #\p #\P) (26 #\[ #\{) (27 #\] #\}) (28 #\Return)
    (30 #\a #\A) (31 #\s #\S) (32 #\d #\D) (33 #\f #\F) (34 #\g #\G) (35 #\h #\H) (36 #\j #\J)
    (37 #\k #\K) (38 #\l #\L) (39 #\; #\:) (40 #\' #\") (41 #\` #\~) (43 #\\ #\|)
    (44 #\z #\Z) (45 #\x #\X) (46 #\c #\C) (47 #\v #\V) (48 #\b #\B) (49 #\n #\N) (50 #\m #\M)
    (51 #\, #\<) (52 #\. #\>) (53 #\/ #\?) (57 #\Space)
    (103 #.(code-char #xF700)) (108 #.(code-char #xF701)) (105 #.(code-char #xF702)) (106 #.(code-char #xF703))))

(defconstant +key-leftshift+ 42)
(defconstant +key-rightshift+ 54)

(defconstant +key-leftctrl+ 29)
(defconstant +key-rightctrl+ 97)

(defun key-character (code shift &optional control)
  (let* ((entry (assoc code +keymap+))
         (char (and entry (if (and shift (third entry)) (third entry) (second entry)))))
    (if (and char control (char<= #\a (char-downcase char) #\z))
        (code-char (- (char-code (char-downcase char)) 96))
        char)))

(defconstant +key-leftalt+ 56)
(defconstant +key-rightalt+ 100)
(defconstant +key-leftmeta+ 125)
(defconstant +key-rightmeta+ 126)
(defconstant +key-esc+ 1)

(defun alt-key-p (code)
  (member code (list +key-leftalt+ +key-rightalt+)))

(defun meta-key-p (code)
  (member code (list +key-leftmeta+ +key-rightmeta+)))

(defun control-key-p (code)
  (member code (list +key-leftctrl+ +key-rightctrl+)))

(defun shift-key-p (code)
  (member code (list +key-leftshift+ +key-rightshift+)))

