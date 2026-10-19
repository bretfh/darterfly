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

(define-low fmin ((a :f64) (b :f64)) (declare (returns :f64))
  (cond ((nan-p a) b) ((nan-p b) a)
        ;; Select negative zero regardless of argument order.
        ((/= (logand a +sign+) (logand b +sign+))
         (if (logand a +sign+) a b))
        ((f< a b) a) (t b)))
(define-low fmax ((a :f64) (b :f64)) (declare (returns :f64))
  (cond ((nan-p a) b) ((nan-p b) a)
        ((/= (logand a +sign+) (logand b +sign+))
         (if (logand a +sign+) b a))
        ((f< a b) b) (t a)))
(define-low fminf ((a :f32) (b :f32)) (declare (returns :f32)) (fmin a b))
(define-low fmaxf ((a :f32) (b :f32)) (declare (returns :f32)) (fmax a b))

(define-low floor ((x :f64)) (declare (returns :f64)) (x87 (x) #(#xD9 #xFC) :rounding #x0400))
(define-low ceil ((x :f64)) (declare (returns :f64)) (x87 (x) #(#xD9 #xFC) :rounding #x0800))
(define-low trunc ((x :f64)) (declare (returns :f64)) (x87 (x) #(#xD9 #xFC) :rounding #x0c00))
(define-low rint ((x :f64)) (declare (returns :f64)) (x87 (x) #(#xD9 #xFC)))

(define-low round ((x :f64)) (declare (returns :f64))
  ;; Integral large values, infinities and NaNs require no arithmetic.
  (when (>= (fabs x) #x4330000000000000) (result x))
  (let* ((whole (trunc x)) (fraction (f- x whole)))
    (if (f>= (fabs fraction) +half+)
        (f+ whole (copysign +one+ x))
        whole)))

(define-low llround ((x :f64)) (float-truncate (round x)))

(define-low lrint ((x :f64)) (float-truncate (rint x)))
(define-low floorf ((x :f32)) (declare (returns :f32)) (floor x))
(define-low ceilf ((x :f32)) (declare (returns :f32)) (ceil x))
(define-low truncf ((x :f32)) (declare (returns :f32)) (trunc x))

(define-low sin ((x :f64)) (declare (returns :f64)) (x87 (x) #(#xD9 #xFE)))
(define-low cos ((x :f64)) (declare (returns :f64)) (x87 (x) #(#xD9 #xFF)))
(define-low sinf ((x :f32)) (declare (returns :f32)) (sin x))
(define-low cosf ((x :f32)) (declare (returns :f32)) (cos x))
(define-low hypotf ((a :f32) (b :f32)) (declare (returns :f32))
  ;; Low widens float arguments internally, so float squares fit in a double.
  (if (or (infinite-p a) (infinite-p b))
      +infinity+
      (sqrt (f+ (f* a a) (f* b b)))))

(define-low tan ((x :f64)) (declare (returns :f64)) (x87 (x) #(#xD9 #xF2 #xDD #xD8)))
(define-low tanf ((x :f32)) (declare (returns :f32)) (tan x))
(define-low atan2 ((y :f64) (x :f64)) (declare (returns :f64)) (x87 (y x) #(#xD9 #xF3)))
(define-low atan ((x :f64)) (declare (returns :f64)) (atan2 x +one+))

(define-low atanf ((x :f32)) (declare (returns :f32)) (atan x))

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

(define-low remainder ((a :f64) (b :f64)) (declare (returns :f64))
  ;; FPREM1 uses a nearest-even quotient independently of the rounding mode.
  ;; Repeat while C2 indicates an incomplete large-exponent reduction.
  (x87 (b a) #(#xD9 #xF5 #xDF #xE0 #xF6 #xC4 #x04 #x75 #xF7 #xDD #xD9)))

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

(define-low roundf ((x :f32)) (declare (returns :f32))
  (if (or (f= x +zero+) (f>= (fabs x) #x4160000000000000)) x (round x)))
(define-low lroundf ((x :f32)) (float-truncate (roundf x)))
(define-low nextafterf ((x :f32) (y :f32)) (declare (returns :f32))
  ;; Arguments are exact widened floats. Add/subtract one float ULP, not
  ;; one double ULP. Clamp the step at the float subnormal quantum 2^-149.
  (cond ((or (nan-p x) (nan-p y)) (f+ x y))
        ((f= x y) y)
        ((f= x +zero+) (copysign #x36A0000000000000 y))
        ((infinite-p x) (copysign #x47EFFFFFE0000000 x))
        (t (let* ((m (fabs x))
                  (up (= (f< x y) (f> x +zero+)))
                  (exponent (- (shr m 52) 1046)))
             ;; Immediately below an exact power of two, ULP is half-sized.
             (when (and (not up) (= (logand m #xFFFFFFFFFFFFF) 0))
               (decf exponent))
             (when (signed< exponent (- 0 149)) (setf exponent (- 0 149)))
             (let ((step (ldexp +one+ exponent)))
               (copysign (if up
                             (if (= m #x47EFFFFFE0000000) +infinity+ (f+ m step))
                             (f- m step)) x))))))

(defun long-double-routines ()
  (list
   (darterfly/asm:routine "__libsa_round_mode"
     ;; Read MXCSR's rounding field (nearest/down/up/zero = 0/1/2/3).
     ;; Reserve stack space: native code cannot use the red zone.
     (dolist (b '(#x48 #x83 #xEC #x08 #x0F #xAE #x1C #x24
                  #x8B #x04 #x24 #xC1 #xE8 #x0D #x83 #xE0 #x03
                  #x48 #x83 #xC4 #x08 #xC3))
       (darterfly/asm:inst byte b)))
   (darterfly/asm:routine "hypotl"
     ;; x87: abs(max) * sqrt(1 + (min/max)^2), without squaring the
     ;; operands themselves. Infinity wins over NaN; preserve +0 for zeros.
     (dolist (b '(
                  #x48 #xBA #x00 #x00 #x00 #x00 #x00 #x00 #x00 #x80 #x0F #xB7
                  #x44 #x24 #x10 #x25 #xFF #x7F #x00 #x00 #x3D #xFF #x7F #x00
                  #x00 #x75 #x0E #x48 #x39 #x54 #x24 #x08 #x75 #x07 #xDB #x6C
                  #x24 #x08 #xD9 #xE1 #xC3 #x0F #xB7 #x44 #x24 #x20 #x25 #xFF
                  #x7F #x00 #x00 #x3D #xFF #x7F #x00 #x00 #x75 #x0E #x48 #x39
                  #x54 #x24 #x18 #x75 #x07 #xDB #x6C #x24 #x18 #xD9 #xE1 #xC3
                  #xDB #x6C #x24 #x18 #xD9 #xE1 #xDB #x6C #x24 #x08 #xD9 #xE1
                  #xDB #xE9 #x7A #x1C #x73 #x02 #xD9 #xC9 #xD9 #xE4 #xDF #xE0
                  #x9E #x74 #x14 #xD9 #xC1 #xD8 #xF1 #xD8 #xC8 #xD9 #xE8 #xDE
                  #xC1 #xD9 #xFA #xDE #xC9 #xDD #xD9 #xC3 #xDE #xC1 #xC3 #xDD
                  #xD9 #xC3))
       (darterfly/asm:inst byte b)))
   (darterfly/asm:routine "frexpl"
     ;; Preserve NaN/Inf/signed zero. FXTRACT also normalizes subnormals;
     ;; store its exact exponent + 1 and return significand * 0.5 in st(0).
     (dolist (b '(#xC7 #x07 #x00 #x00 #x00 #x00 #x0F #xB7 #x44 #x24 #x10 #x25
                  #xFF #x7F #x00 #x00 #x3D #xFF #x7F #x00 #x00 #x74 #x2B #x85
                  #xC0 #x75 #x08 #x48 #x83 #x7C #x24 #x08 #x00 #x74 #x1F #x48
                  #x83 #xEC #x08 #xC7 #x04 #x24 #x00 #x00 #x00 #x3F #xDB #x6C
                  #x24 #x10 #xD9 #xF4 #xD9 #xC9 #xDB #x1F #xFF #x07 #xD8 #x0C
                  #x24 #x48 #x83 #xC4 #x08 #xC3 #xDB #x6C #x24 #x08 #xC3))
       (darterfly/asm:inst byte b)))
   (darterfly/asm:routine "atan2l"
     ;; SysV long double arguments occupy 16-byte stack slots; fpatan
     ;; computes atan2(st(1), st(0)) and leaves the extended result in st(0).
     (dolist (b '(#xDB #x6C #x24 #x08 #xDB #x6C #x24 #x18 #xD9 #xF3 #xC3))
       (darterfly/asm:inst byte b)))
   (darterfly/asm:routine "truncl"
     (dolist (b '(#x48 #x83 #xEC #x08 #xD9 #x3C #x24 #x66 #x8B #x04 #x24 #x66 #x0D #x3F #x0C #x66 #x89 #x44 #x24 #x02
                  #xDB #xE2 #xD9 #x6C #x24 #x02 #xDB #x6C #x24 #x10 #xD9 #xFC #xDB #xE2 #xD9 #x2C #x24 #x48 #x83 #xC4 #x08 #xC3))
       (darterfly/asm:inst byte b)))
   (darterfly/asm:routine "ldexpl"
     (dolist (b '(#x48 #x83 #xEC #x08 #x89 #x3C #x24 #xDB #x04 #x24 #xDB #x6C #x24 #x10 #xD9 #xFD #xDD #xD9 #x48 #x83 #xC4 #x08 #xC3))
       (darterfly/asm:inst byte b)))))

;; LLVM's own code lowers some expressions to these libm entry points.
;; Reuse the same x87 implementation and C ABI as the existing math routines.
(define-low exp2 ((x :f64)) (declare (returns :f64))
  (cond ((nan-p x) x)
        ((f>= x #x4090000000000000) +infinity+) ; 1024
        ((f< x #xC090CC0000000000) +zero+)     ; -1075
        (t (x87 (x) +exp2+))))
(define-low log2f ((x :f32)) (declare (returns :f32)) (log2 x))

(define-low expf ((x :f32)) (declare (returns :f32)) (exp x))
(define-low atan2f ((y :f32) (x :f32)) (declare (returns :f32)) (atan2 y x))

(define-low tanhf ((x :f32)) (declare (returns :f32)) (tanh x))

;; Float entry points reuse the shared double operations after exact widening.
(define-low fmodf ((x :f32) (y :f32)) (declare (returns :f32)) (fmod x y))
(define-low powf ((x :f32) (y :f32)) (declare (returns :f32)) (pow x y))
(define-low copysignf ((x :f32) (y :f32)) (declare (returns :f32)) (copysign x y))
(define-low acosf ((x :f32)) (declare (returns :f32)) (acos x))
(define-low asinf ((x :f32)) (declare (returns :f32)) (asin x))
(define-low log10f ((x :f32)) (declare (returns :f32)) (log10 x))
(define-low cbrtf ((x :f32)) (declare (returns :f32)) (cbrt x))
(define-low lrintf ((x :f32)) (float-truncate (x87 (x) #(#xD9 #xFC))))
(define-low llroundf ((x :f32)) (float-truncate (roundf x)))

(define-low ldexpf ((x :f32) (e :u32)) (declare (returns :f32)) (ldexp x e))
(define-low frexpf ((x :f32) e) (declare (returns :f32)) (frexp x e))

;; Sun/FreeBSD/musl erff approximation, evaluated in Low's widened float
;; representation. Original coefficient bits are preserved exactly.
;; Copyright (C) 1993 Sun Microsystems, Inc. Permission notice:
;; licenses/erff-COPYRIGHT.

(define-low erff-pp ((x :f64)) (declare (returns :f64))
  (f+ #x3FC06EBA80000000
       (f* x (f+ #xBFD4CD7D60000000
       (f* x (f+ #xBF9D2A51E0000000
       (f* x (f+ #xBF77A29120000000
       (f* x #xBEF8EAD620000000)))))))))

(define-low erff-qq ((x :f64)) (declare (returns :f64))
  (f+ +one+
       (f* x (f+ #x3FD97779C0000000
       (f* x (f+ #x3FB0A54C60000000
       (f* x (f+ #x3F74D022C0000000
       (f* x (f+ #x3F215DC920000000
       (f* x #xBED09C4340000000)))))))))))

(define-low erff-pa ((x :f64)) (declare (returns :f64))
  (f+ #xBF6359B8C0000000
       (f* x (f+ #x3FDA8D00A0000000
       (f* x (f+ #xBFD7D24100000000
       (f* x (f+ #x3FD45FCA80000000
       (f* x (f+ #xBFBC639840000000
       (f* x (f+ #x3FA22A3660000000
       (f* x #xBF61BF3800000000)))))))))))))

(define-low erff-qa ((x :f64)) (declare (returns :f64))
  (f+ +one+
       (f* x (f+ #x3FBB3E6620000000
       (f* x (f+ #x3FE14AF0A0000000
       (f* x (f+ #x3FB2635CE0000000
       (f* x (f+ #x3FC02660E0000000
       (f* x (f+ #x3F8BEDC260000000
       (f* x #x3F888B5460000000)))))))))))))

(define-low erff-ra ((x :f64)) (declare (returns :f64))
  (f+ #xBF84341260000000
       (f* x (f+ #xBFE63416E0000000
       (f* x (f+ #xC0251E0440000000
       (f* x (f+ #xC04F300AE0000000
       (f* x (f+ #xC0644CB180000000
       (f* x (f+ #xC067135CE0000000
       (f* x (f+ #xC054526560000000
       (f* x #xC023A0EFC0000000)))))))))))))))

(define-low erff-sa ((x :f64)) (declare (returns :f64))
  (f+ +one+
       (f* x (f+ #x4033A6B9C0000000
       (f* x (f+ #x4061350C60000000
       (f* x (f+ #x407B290DE0000000
       (f* x (f+ #x40842B1920000000
       (f* x (f+ #x407AD02160000000
       (f* x (f+ #x405B28A3E0000000
       (f* x (f+ #x401A47EF80000000
       (f* x #xBFAEEFF2E0000000)))))))))))))))))

(define-low erff-rb ((x :f64)) (declare (returns :f64))
  (f+ #xBF84341240000000
       (f* x (f+ #xBFE993BA80000000
       (f* x (f+ #xC031C20960000000
       (f* x (f+ #xC064145D40000000
       (f* x (f+ #xC083EC8820000000
       (f* x (f+ #xC090046160000000
       (f* x #xC07E384EA0000000)))))))))))))

(define-low erff-sb ((x :f64)) (declare (returns :f64))
  (f+ +one+
       (f* x (f+ #x403E568B20000000
       (f* x (f+ #x40745CAE20000000
       (f* x (f+ #x409802EB20000000
       (f* x (f+ #x40A8FFB760000000
       (f* x (f+ #x40A3F219C0000000
       (f* x (f+ #x407DA874E0000000
       (f* x #xC03670E240000000)))))))))))))))

(define-low erff-tail ((x :f64)) (declare (returns :f64))
  (when (f< x #x3FF4000000000000)
    (let ((s (f- x +one+)))
      (result (f- (f- +one+ #x3FEB0AC160000000)
                  (f/ (erff-pa s) (erff-qa s))))))
  (let* ((s (f/ +one+ (f* x x)))
         (small (f< x #x4006DB6DA0000000))
         (r (if small (erff-ra s) (erff-rb s)))
         (q (if small (erff-sa s) (erff-sb s)))
         (z (logand x #xFFFFFC0000000000)))
    (f/ (f* (exp (f- (negate (f* z z)) #x3FE2000000000000))
            (exp (f+ (f* (f- z x) (f+ z x)) (f/ r q)))) x)))

(define-low erff ((x :f32)) (declare (returns :f32))
  (when (nan-p x) (result x))
  (when (infinite-p x) (result (copysign +one+ x)))
  (let ((a (fabs x)))
    (when (f< a #x3FEB000000000000)
      (when (f< a #x3E30000000000000)
        (result (f* #x3FC0000000000000
                    (f+ (f* #x4020000000000000 x) (f* #x3FF06EBA80000000 x)))))
      (let ((z (f* x x)))
        (result (f+ x (f* x (f/ (erff-pp z) (erff-qq z)))))))
    (copysign (if (f< a #x4018000000000000)
                  (f- +one+ (erff-tail a))
                  (f- +one+ #x3870000000000000)) x)))

(define-low logf ((x :f32)) (declare (returns :f32)) (log x))
(define-low exp2f ((x :f32)) (declare (returns :f32)) (exp2 x))
(define-low remainderf ((x :f32) (y :f32))
  (declare (returns :f32)) (remainder x y))
