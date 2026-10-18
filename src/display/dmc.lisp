(defpackage #:darterfly/display
  (:use #:cl)
  (:export #:load-dmc #:allow-dc #:enable-psr #:disable-psr #:screen-changed #:start-display
           #:second-surface #:show-surface #:live-surface #:wait-for-flip #:flip
           #:release-unused-wells #:allow-dc6 #:forbid-dc #:awake #:watch-psr))
(in-package #:darterfly/display)

(defparameter *dmc-path* "/Library/Firmware/i915/adlp_dmc.bin")

(defconstant +dc-state-en+ #x45504)
(defconstant +dc-state-debug+ #x45520)
(defconstant +ssp-base+ #x8F074)

(defvar *registers* nil)

(defun graphics ()
  (find-if (lambda (d) (and (= (devices:config-read-16 d 0) #x8086)
                            (= (ash (devices:config-read-32 d 8) -8) #x030000)))
           (devices:find-entries 'devices:pci-node)))

(defun registers ()
  (or *registers*
      (let ((g (or (graphics) (error "no Intel graphics on the PCI bus"))))
        (setf *registers* (devices:ml-io-map (devices::bar-address g 0) #x200000)))))

(pushnew 'forget-registers sb-ext:*save-hooks*)

(defun forget-registers () (setf *registers* nil))

(defun reg (offset) (devices:mmio-read (+ (registers) offset) 32))
(defun (setf reg) (value offset) (devices:mmio-write (+ (registers) offset) 32 value) value)

(defun u32le (v i)
  (logior (aref v i) (ash (aref v (+ i 1)) 8) (ash (aref v (+ i 2)) 16) (ash (aref v (+ i 3)) 24)))

(defun read-file-octets (path)
  (with-open-file (s path :element-type '(unsigned-byte 8))
    (let ((v (make-array (file-length s) :element-type '(unsigned-byte 8))))
      (read-sequence v s)
      v)))

(defconstant +null-event+ #x30100)
(defconstant +pipe-a-dmc-control+ #x45250)

(defun dmc-base (id) (if (zerop id) #x8F000 (+ #x5F000 (* #x400 (1- id)))))

(defun dmc-programs (v)
  (let* ((package (* 4 (u32le v 4)))
         (entries (u32le v (+ package 12)))
         (programs (+ package (* 4 (aref v package))))
         (chosen nil))
    (unless (= (u32le v 0) 9) (error "~a is not a DMC package" *dmc-path*))
    (loop for i below entries
          for at = (+ package 16 (* 12 i))
          for id = (aref v (+ at 1))
          when (and (= (aref v (+ at 2)) (char-code #\*)) (not (assoc id chosen)))
            do (let ((h (+ programs (* 4 (u32le v (+ at 4))))))
                 (unless (and (= (u32le v h) #x40403E3E) (= (aref v (+ h 5)) 3) (= (* 4 (aref v (+ h 4))) 256))
                   (error "DMC program ~d does not have a version 3 header" id))
                 (push (list id
                             :start (u32le v (+ h 20))
                             :version (u32le v (+ h 16))
                             :program (subseq v (+ h 256) (+ h 256 (* 4 (u32le v (+ h 12)))))
                             :writes (loop for j below (u32le v (+ h 92))
                                           collect (cons (u32le v (+ h 96 (* 4 j))) (u32le v (+ h 176 (* 4 j))))))
                       chosen)))
    (unless (assoc 0 chosen) (error "no main DMC program in ~a" *dmc-path*))
    (sort chosen #'< :key #'first)))

(defun event-control-p (id address)
  (let ((ctl (+ (dmc-base id) #x34)))
    (and (<= ctl address) (< address (+ ctl 32)))))

(defun load-dmc ()
  (let ((programs (dmc-programs (read-file-octets *dmc-path*))))
    (dolist (gate '(#x4654C #x46550 #x46554 #x46558))
      (setf (reg gate) (logior (reg gate) (ash 1 12))))
    (loop for (id) in programs
          do (dotimes (i 8)
               (setf (reg (+ (dmc-base id) #x34 (* 4 i))) +null-event+
                     (reg (+ (dmc-base id) #x4 (* 4 i))) 0)))
    (loop for (nil . dmc) in programs
          do (let ((program (getf dmc :program)) (start (getf dmc :start)))
               (loop for i from 0 below (length program) by 4
                     do (setf (reg (+ start i)) (u32le program i)))))
    (loop for (id . dmc) in programs
          do (loop for (address . value) in (getf dmc :writes)
                   do (setf (reg address) (if (and (plusp id) (event-control-p id address)) +null-event+ value))))
    (setf (reg +dc-state-debug+) (logior (reg +dc-state-debug+) 3))
    (dolist (gate '(#x46554 #x46558))
      (setf (reg gate) (logandc2 (reg gate) (ash 1 12))))
    (when (logbitp 31 (reg #x70008))
      (setf (reg +pipe-a-dmc-control+) (logior (reg +pipe-a-dmc-control+) 1)))
    (list :programs (mapcar #'first programs) :version (getf (rest (assoc 0 programs)) :version) :ssp (reg +ssp-base+))))

(defun allow-dc (level)
  (let ((value (ecase level (0 0) (5 1) (6 2))))
    (loop repeat 100
          do (setf (reg +dc-state-en+) (logior (logandc2 (reg +dc-state-en+) 3) value))
             (when (= (logand (reg +dc-state-en+) 3) value) (return value))
             (sleep 0.001))))
