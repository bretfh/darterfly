(in-package #:darterfly/libsa)

;; Integer-significand FMA adapted from musl src/math/fma.c (MIT).
;; See licenses/musl-COPYRIGHT. Keep the exact product and a sticky bit;
;; ordinary x*y+z would lose the residual used by JSC's decimal conversion.
;; This implementation needs no AVX/FMA CPU feature.
(define-low fma-normalize (x mantissa exponent signp)
  (let ((e (logand (shr x 52) #x7ff))
        (sign (logand (shr x 52) #x800)))
    (when (= e 0)
      (progn
        (setf x (f* x #x43e0000000000000))
        (setf e (logand (shr x 52) #x7ff))
        (setf e (if (= e 0) #x800 (- e 63)))))
    (progn
      (setf (mem :u64 mantissa) (shl (logior (logand x #xfffffffffffff)
                                     #x10000000000000) 1))
      (setf (mem :u64 exponent) (- e 1076))
      (setf (mem :u64 signp) sign))))

(define-low fma-clz (x)
  (let ((n 0))
    (while (= (logand x #x8000000000000000) 0)
      (progn
        (setf x (shl x 1))
        (setf n (+ n 1))))
    n))

(define-low fma-single-round ((x :f32))
  (declare (returns :f32)) x)

(define-low fma ((x :f64) (y :f64) (z :f64))
  (declare (returns :f64))
  (let ((xm 0) (xe 0) (xs 0) (ym 0) (ye 0) (ys 0)
        (zm 0) (ze 0) (zs 0))
    (fma-normalize x (address xm) (address xe) (address xs))
    (fma-normalize y (address ym) (address ye) (address ys))
    (fma-normalize z (address zm) (address ze) (address zs))
    (when (or (signed>= xe 971) (signed>= ye 971))
      (result (f+ (f* x y) z)))
    (when (signed>= ze 971)
      (result (if (signed> ze 971) (f* x y) z)))
    (let* ((t1 (* (logand xm #xffffffff) (logand ym #xffffffff)))
           (t2 (+ (* (logand xm #xffffffff) (shr ym 32))
                  (* (shr xm 32) (logand ym #xffffffff))))
           (lo (+ t1 (shl t2 32)))
           (hi (+ (* (shr xm 32) (shr ym 32)) (shr t2 32)
                  (if (> t1 lo) 1 0)))
           (zl 0) (zh 0) (e (+ xe ye)) (d (- ze e))
           (sign (logxor xs ys)) (nonzero 1))
      (if (signed> d 0)
          (if (< d 64)
              (progn
                (setf zl (shl zm d))
                (setf zh (shr zm (- 64 d))))
              (progn
                (progn
                  (setf zh zm)
                  (setf e (- ze 64))
                  (setf d (- d 64)))
                (cond ((= d 0))
                      ((< d 64)
                       (progn
                         (setf lo (logior (shl hi (- 64 d)) (shr lo d)
                                       (if (= (shl lo (- 64 d)) 0) 0 1)))
                         (setf hi (shr hi d))))
                      (t (progn
                           (setf lo 1)
                           (setf hi 0))))))
          (progn
            (setf d (- 0 d))
            (setf zl (cond ((= d 0) zm)
                           ((< d 64)
                            (logior (shr zm d)
                                    (if (= (shl zm (- 64 d)) 0) 0 1)))
                           (t 1)))))
      (if (= sign zs)
          (progn
            (progn
              (setf lo (+ lo zl))
              (setf hi (+ hi zh (if (< lo zl) 1 0)))))
          (let ((old lo))
            (progn
              (setf lo (- lo zl))
              (setf hi (- hi zh (if (< old lo) 1 0))))
            (when (/= (shr hi 63) 0)
              (progn
                (setf lo (- 0 lo))
                (setf hi (- (- 0 hi) (if (= lo 0) 0 1)))
                (setf sign (if (= sign 0) 1 0))))
            (setf nonzero (if (= hi 0) 0 1))))
      (cond ((/= nonzero 0)
             (progn
               (setf e (+ e 64))
               (setf d (- (fma-clz hi) 1))
               (setf hi (logior (shl hi d) (shr lo (- 64 d))
                              (if (= (shl lo d) 0) 0 1)))))
            ((/= lo 0)
             (progn
               (setf d (- (fma-clz lo) 1))
               (setf hi (if (signed< d 0)
                          (logior (shr lo 1) (logand lo 1))
                          (shl lo d)))))
            (t (result (f+ (f* x y) z))))
      (setf e (- e d))
      (let* ((i (if (= sign 0) hi (- 0 hi))) (r (float-of i)))
        (when (signed< e -1084)
          (if (= e -1085)
              (let ((c (if (= sign 0) #x43e0000000000000
                           #xc3e0000000000000)))
                (when (f= r c)
                  ;; Match underflow signalling at the normal boundary.
                  (result (f* #x07f0000000000000
                              (fma-single-round
                               (f* #x341ffffff0000000 r)))))
                (when (/= (shl hi 53) 0)
                  (progn
                    (setf i (logior (shr hi 1) (logand hi 1)
                                 #x4000000000000000))
                    (setf r (float-of (if (= sign 0) i (- 0 i))))
                    (setf r (f- (f* +two+ r) c))
                    ;; Force the underflow exception for an inexact result.
                    (let ((tiny (f* #x07f0000000000000 r)))
                      (setf r (f+ r (f* (f* tiny tiny) (f- r r))))))))
              (progn
                (progn
                  (setf i (shl (logior (shr hi 10)
                                    (if (= (shl hi 54) 0) 0 1)) 10))
                  (setf r (float-of (if (= sign 0) i (- 0 i))))))))
        (scalbn r e)))))

;; Float FMA adapted from David Schultz's FreeBSD implementation in musl.
;; See licenses/fmaf-COPYRIGHT. A float product is exact in a double;
;; repair inexact midpoint sums before converting back to float.
(define-low fmaf ((x :f32) (y :f32) (z :f32))
  (declare (returns :f32))
  (let* ((xy (f* x y)) (sum (f+ xy z))
         (e (logand (shr sum 52) #x7ff)))
    (when (or (/= (logand sum #x1fffffff) #x10000000)
              (= e #x7ff)
              (and (f= (f- sum xy) z) (f= (f- sum z) xy))
              (/= (__libsa_round_mode) 0))
      (result sum))
    (let* ((negative (shr sum 63))
           (error (if (= negative (f> z xy))
                      (f+ (f- xy sum) z)
                      (f+ (f- z sum) xy))))
      (if (= negative (f< error +zero+)) (+ sum 1) (- sum 1)))))
