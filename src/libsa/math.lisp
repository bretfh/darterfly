(in-package #:darterfly/libsa)

(defconstant +nan+ #x7FF8000000000000)
(defconstant +infinity+ #x7FF0000000000000)
(defconstant +minus-infinity+ #xFFF0000000000000)
(defconstant +sign+ #x8000000000000000)
(defconstant +one+ #x3FF0000000000000)
(defconstant +half+ #x3FE0000000000000)
(defconstant +two+ #x4000000000000000)
(defconstant +zero+ 0)

(defparameter +exp2+ '(#xD9 #xC0 #xD9 #xFC #xDC #xE9 #xD9 #xC9 #xD9 #xF0 #xD9 #xE8 #xDE #xC1 #xD9 #xFD #xDD #xD9))

(define-low nan-p (x) (not (f= x x)))
(define-low infinite-p (x) (= (logand x (lognot +sign+)) +infinity+))
(define-low negate (x) (logxor x +sign+))

(define-low sqrt ((x :f64)) (declare (returns :f64)) (x87 (x) #(#xD9 #xFA)))
(define-low sqrtf ((x :f32)) (declare (returns :f32)) (x87 (x) #(#xD9 #xFA)))

(define-low fabs ((x :f64)) (declare (returns :f64)) (logand x (lognot +sign+)))
(define-low fabsf ((x :f32)) (declare (returns :f32)) (logand x (lognot +sign+)))

(define-low copysign ((a :f64) (b :f64)) (declare (returns :f64))
  (logior (logand a (lognot +sign+)) (logand b +sign+)))

(define-low floor ((x :f64)) (declare (returns :f64)) (x87 (x) #(#xD9 #xFC) :rounding #x0400))
(define-low ceil ((x :f64)) (declare (returns :f64)) (x87 (x) #(#xD9 #xFC) :rounding #x0800))
(define-low trunc ((x :f64)) (declare (returns :f64)) (x87 (x) #(#xD9 #xFC) :rounding #x0c00))
(define-low rint ((x :f64)) (declare (returns :f64)) (x87 (x) #(#xD9 #xFC) :rounding #x0000))

(define-low round ((x :f64)) (declare (returns :f64))
  (if (f< x +zero+)
      (negate (floor (f+ (negate x) +half+)))
      (floor (f+ x +half+))))

(define-low lrint ((x :f64)) (float-truncate (rint x)))
(define-low floorf ((x :f32)) (declare (returns :f32)) (floor x))
(define-low ceilf ((x :f32)) (declare (returns :f32)) (ceil x))
(define-low truncf ((x :f32)) (declare (returns :f32)) (trunc x))

(define-low sin ((x :f64)) (declare (returns :f64)) (x87 (x) #(#xD9 #xFE)))
(define-low cos ((x :f64)) (declare (returns :f64)) (x87 (x) #(#xD9 #xFF)))
(define-low tan ((x :f64)) (declare (returns :f64)) (x87 (x) #(#xD9 #xF2 #xDD #xD8)))
(define-low atan2 ((y :f64) (x :f64)) (declare (returns :f64)) (x87 (y x) #(#xD9 #xF3)))
(define-low atan ((x :f64)) (declare (returns :f64)) (atan2 x +one+))

(define-low asin ((x :f64)) (declare (returns :f64))
  (atan2 x (sqrt (f* (f- +one+ x) (f+ +one+ x)))))

(define-low acos ((x :f64)) (declare (returns :f64))
  (atan2 (sqrt (f* (f- +one+ x) (f+ +one+ x))) x))

(define-low log2 ((x :f64)) (declare (returns :f64))
  (cond ((f< x +zero+) +nan+)
        ((f= x +zero+) +minus-infinity+)
        (t (x87 (x) #(#xD9 #xE8 #xD9 #xC9 #xD9 #xF1)))))

(define-low log ((x :f64)) (declare (returns :f64))
  (cond ((f< x +zero+) +nan+)
        ((f= x +zero+) +minus-infinity+)
        (t (x87 (x) #(#xD9 #xED #xD9 #xC9 #xD9 #xF1)))))

(define-low log10 ((x :f64)) (declare (returns :f64))
  (cond ((f< x +zero+) +nan+)
        ((f= x +zero+) +minus-infinity+)
        (t (x87 (x) #(#xD9 #xEC #xD9 #xC9 #xD9 #xF1)))))

(define-low log1p ((x :f64)) (declare (returns :f64)) (log (f+ +one+ x)))

(define-low exp ((x :f64)) (declare (returns :f64))
  (cond ((nan-p x) x)
        ((f> x #x40862E6666666666) +infinity+)
        ((f< x #xC08749999999999A) +zero+)
        (t (x87 (x) (append '(#xD9 #xEA #xDE #xC9) +exp2+)))))

(define-low expm1 ((x :f64)) (declare (returns :f64)) (f- (exp x) +one+))

(define-low pow ((x :f64) (y :f64)) (declare (returns :f64))
  (cond ((f= y +zero+) +one+)
        ((f= x +one+) +one+)
        ((or (nan-p x) (nan-p y)) +nan+)
        ((f= x +zero+) (if (f> y +zero+) +zero+ +infinity+))
        ((f< x +zero+)
         (let ((i (trunc y)))
           (if (not (f= i y))
               +nan+
               (let ((r (x87 ((negate x) y) (append '(#xD9 #xC9 #xD9 #xF1) +exp2+))))
                 (if (f= (fmod i +two+) +zero+) r (negate r))))))
        (t (x87 (x y) (append '(#xD9 #xC9 #xD9 #xF1) +exp2+)))))

(define-low fmod ((a :f64) (b :f64)) (declare (returns :f64))
  (x87 (b a) #(#xD9 #xF8 #xDF #xE0 #xF6 #xC4 #x04 #x75 #xF7 #xDD #xD9)))

(define-low hypot ((a :f64) (b :f64)) (declare (returns :f64)) (sqrt (f+ (f* a a) (f* b b))))
(define-low sinh ((x :f64)) (declare (returns :f64)) (f/ (f- (exp x) (exp (negate x))) +two+))
(define-low cosh ((x :f64)) (declare (returns :f64)) (f/ (f+ (exp x) (exp (negate x))) +two+))

(define-low tanh ((x :f64)) (declare (returns :f64))
  (cond ((f> x #x4034000000000000) +one+)
        ((f< x #xC034000000000000) (negate +one+))
        (t (let ((e (exp (f* +two+ x))))
             (f/ (f- e +one+) (f+ e +one+))))))

(define-low asinh ((x :f64)) (declare (returns :f64))
  (if (f< x +zero+)
      (negate (log (f+ (negate x) (sqrt (f+ (f* x x) +one+)))))
      (log (f+ x (sqrt (f+ (f* x x) +one+))))))

(define-low acosh ((x :f64)) (declare (returns :f64)) (log (f+ x (sqrt (f- (f* x x) +one+)))))
(define-low atanh ((x :f64)) (declare (returns :f64)) (f* +half+ (log (f/ (f+ +one+ x) (f- +one+ x)))))

(define-low cbrt ((x :f64)) (declare (returns :f64))
  (if (f< x +zero+)
      (negate (pow (negate x) (f/ +one+ #x4008000000000000)))
      (pow x (f/ +one+ #x4008000000000000))))

(define-low ldexp ((x :f64) (e :u32)) (declare (returns :f64))
  (x87 (x (float-of (sign-extend :u32 e))) #(#xD9 #xC9 #xD9 #xFD #xDD #xD9)))

(define-low scalbn ((x :f64) (e :u32)) (declare (returns :f64)) (ldexp x e))

(define-low frexp ((x :f64) e) (declare (returns :f64))
  (when (or (f= x +zero+) (nan-p x) (infinite-p x))
    (setf (mem :u32 e) 0)
    (result x))
  (let ((k 0) (m (fabs x)))
    (while (f>= m +one+) (setf m (f/ m +two+)) (incf k))
    (while (f< m +half+) (setf m (f* m +two+)) (decf k))
    (setf (mem :u32 e) k)
    (if (f< x +zero+) (negate m) m)))

(define-low modf ((x :f64) ip) (declare (returns :f64))
  (setf (mem :u64 ip) (trunc x))
  (f- x (mem :u64 ip)))

(define-low nextafter ((x :f64) (y :f64)) (declare (returns :f64))
  (cond ((or (nan-p x) (nan-p y)) (f+ x y))
        ((f= x y) y)
        ((f= x +zero+) (if (f> y +zero+) 1 (logior 1 +sign+)))
        ((= (f< x y) (f> x +zero+)) (+ x 1))
        (t (- x 1))))

(defun long-double-routines ()
  (list
   (darterfly/asm:routine "truncl"
     (dolist (b '(#x48 #x83 #xEC #x08 #xD9 #x3C #x24 #x66 #x8B #x04 #x24 #x66 #x0D #x3F #x0C #x66 #x89 #x44 #x24 #x02
                  #xDB #xE2 #xD9 #x6C #x24 #x02 #xDB #x6C #x24 #x10 #xD9 #xFC #xDB #xE2 #xD9 #x2C #x24 #x48 #x83 #xC4 #x08 #xC3))
       (darterfly/asm:inst byte b)))
   (darterfly/asm:routine "ldexpl"
     (dolist (b '(#x48 #x83 #xEC #x08 #x89 #x3C #x24 #xDB #x04 #x24 #xDB #x6C #x24 #x10 #xD9 #xFD #xDD #xD9 #x48 #x83 #xC4 #x08 #xC3))
       (darterfly/asm:inst byte b)))))
