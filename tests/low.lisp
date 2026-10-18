(defpackage #:darterfly/low-test
  (:use #:cl #:darterfly/low))
(in-package #:darterfly/low-test)

(define-low low-add8 (a b c d e f g h) (+ a b c d e f g h))

(define-low low-nested (x)
  (+ x (c-check) (+ 1 (c-check)) (c-eight 1 2 3 4 5 6 7 8) (+ 2 (+ 3 (c-eight 8 7 6 5 4 3 2 1)))))

(define-low low-calls-low () (low-add8 1 2 3 4 5 6 7 (+ 4 (low-add8 0 0 0 0 0 0 0 4))))

(define-low low-varargs () (+ 1 (c-sum 3 10 20 30) (+ 2 (c-sum 7 1 2 3 4 5 6 7))))

(define-low low-signed (a b)
  (+ (if (signed< a b) 100 0) (if (signed> a b) 10 0) (if (signed<= a b) 1 0)))

(define-low low-shifts (x) (+ (sar x 2) (sign-extend :u8 #xFF) (sign-extend :u32 #xFFFFFFFE)))

(define-low low-divide (a b) (+ (* 10 (signed-truncate a b)) (signed-rem a b)))

(define-low low-deep () (+ 1 (+ 1 (+ 1 (+ 1 (+ 1 (c-eight 1 1 1 1 1 1 1 (+ 1 (c-check)))))))))

(define-low low-pointer () (+ 1 (call-pointer (code-address c-twice) (+ 3 (c-check)))))

(define-low low-callback (x) (+ (c-apply (code-address c-twice) x) (c-apply (code-address c-twice) (+ 1 x))))

(in-package #:darterfly/test)

(def-suite low :in host)
(in-suite low)

(test low-follows-the-c-calling-convention
  (let* ((dir (scratch))
         (object (merge-pathnames "low.o" dir))
         (program (merge-pathnames "low-test" dir)))
    (with-open-file (s object :direction :output :element-type '(unsigned-byte 8) :if-exists :supersede)
      (write-sequence (darterfly/low:package-object "DARTERFLY/LOW-TEST") s))
    (sh "clang" "-O0" "-fno-omit-frame-pointer" "-o" (uiop:native-namestring program)
        (uiop:native-namestring (darterfly-file "tests/low-harness.c")) (uiop:native-namestring object))
    (let ((out (sh (uiop:native-namestring program))))
      (flet ((line (key) (find-if (lambda (l) (uiop:string-prefix-p key l)) (uiop:split-string out :separator '(#\Newline)))))
        (is (equal "add8 36" (line "add8 ")) "eight arguments, two on the stack")
        (is (equal (format nil "nested ~d" (+ 10 1 2 204 (+ 5 120))) (line "nested ")))
        (is (equal "calls-low 36" (line "calls-low ")))
        (is (equal "varargs 91" (line "varargs ")) "variadic C callee")
        (is (equal "signed 101 10 1" (line "signed ")))
        (is (equal "shifts -19" (line "shifts ")) "sar and sign extension")
        (is (equal "divide -31" (line "divide ")) "idiv truncates toward zero")
        (is (equal "deep 49" (line "deep ")))
        (is (equal "pointer 9" (line "pointer ")))
        (is (equal "callback 84" (line "callback ")) "C calls back into darterfly/low")
        (is (equal "preserved 1" (line "preserved ")) "rbx and r12-r15 survive")
        (is (equal "misaligned 0" (line "misaligned ")) "every C callee sees a 16-byte aligned stack")))))
