(in-package #:darterfly/kern)

(defconstant +kalloc-base+ #xFFFFFF0000000000)
(defconstant +kalloc-size+ (ash 64 30))
(defconstant +read-write+ 3)

(define-global kalloc-next :u64)
(define-global zones :u64 :count 64)

(define-low kalloc-init ()
  (setf kalloc-next +kalloc-base+)
  (vm-map-enter +kalloc-base+ +kalloc-size+ +read-write+))

(define-low zone-of (size)
  (let ((z 4))
    (while (< (shl 1 z) size) (incf z))
    z))

(define-low kalloc (size)
  (let ((z (zone-of (+ size 16)))
        (h 0))
    (if (ref zones z)
        (progn
          (setf h (ref zones z))
          (setf (ref zones z) (mem :u64 h)))
        (let ((align (if (< (shl 1 z) +page-size+) 16 +page-size+)))
          (setf kalloc-next (logand (+ kalloc-next align -1) (lognot (- align 1))))
          (setf h kalloc-next)
          (incf kalloc-next (shl 1 z))))
    (setf (mem :u64 h) z)
    (+ h 16)))

(define-low kfree (p)
  (when p
    (let ((h (- p 16))
          (z (mem :u64 (- p 16))))
      (setf (mem :u64 h) (ref zones z))
      (setf (ref zones z) h))))

(define-global range-next :u64 :count 256)
(define-global range-end :u64 :count 256)
(define-global nranges :u64)
(define-global current :u64)
(define-global free-list :u64)
(define-global free-count :u64)

(defconstant +memory-map+ 1032)
(defconstant +memory-map-size+ 1036)
(defconstant +descriptor-size+ 1040)

(define-low vm-page-bootstrap (args)
  (let ((size (mem :u32 (+ args +descriptor-size+)))
        (n (truncate (mem :u32 (+ args +memory-map-size+)) (mem :u32 (+ args +descriptor-size+))))
        (i 0))
    (while (and (< i n) (< nranges 256))
      (let* ((r (+ (mem :u32 (+ args +memory-map+)) (* i size)))
             (type (mem :u32 r))
             (physical (mem :u64 (+ r 8)))
             (start (if (< physical #x100000) #x100000 physical))
             (end (+ physical (* (mem :u64 (+ r 24)) +page-size+))))
        (when (and (or (= type 3) (= type 4) (= type 7)) (< start end))
          (setf (ref range-next nranges) start)
          (setf (ref range-end nranges) end)
          (incf free-count (truncate (- end start) +page-size+))
          (incf nranges)))
      (incf i))))

(define-low vm-page-grab ()
  (when free-list
    (let ((pa free-list))
      (setf free-list (mem :u64 (+ pa +physmap-base+)))
      (decf free-count)
      (result pa)))
  (while (and (< current nranges) (>= (ref range-next current) (ref range-end current)))
    (incf current))
  (when (= current nranges) (result 0))
  (let ((pa (ref range-next current)))
    (incf (ref range-next current) +page-size+)
    (decf free-count)
    pa))

(define-low vm-page-free (pa)
  (setf (mem :u64 (+ pa +physmap-base+)) free-list)
  (setf free-list pa)
  (incf free-count))

(define-low vm-page-free-count ()
  free-count)

(define-low memcpy (d s n)
  (rep-movsb d s n)
  d)

(define-low memset ((d :u64) (c :u8) n)
  (rep-stosb d c n)
  d)

(define-low memmove (d s n)
  (if (or (<= d s) (>= d (+ s n)))
      (memcpy d s n)
      (progn
        (while n
          (decf n)
          (setf (mem :u8 (+ d n)) (mem :u8 (+ s n))))
        d)))

(define-low memcmp (a b n)
  (while n
    (when (/= (mem :u8 a) (mem :u8 b))
      (result (- (mem :u8 a) (mem :u8 b))))
    (incf a)
    (incf b)
    (decf n))
  0)

(define-low bzero (d n)
  (memset d 0 n))

(defun kern-object ()
  (package-object "DARTERFLY/KERN" :extra '("va_next") :routines (append (start-routines) (stub-routines))))
