(defpackage #:darterfly/display
  (:use #:cl)
  (:export #:load-dmc #:allow-dc #:enable-psr #:disable-psr #:screen-changed #:start-display
           #:second-surface #:show-surface #:live-surface #:wait-for-flip))
(in-package #:darterfly/display)

(defparameter *dmc-path* "/Library/Firmware/i915/adlp_dmc.bin")

(defconstant +dc-state-en+ #x45504)
(defconstant +dc-state-debug+ #x45520)
(defconstant +evt-htp+ #x8F004)
(defconstant +evt-ctl+ #x8F034)
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

(defun main-dmc (v)
  (let* ((package (* 4 (u32le v 4)))
         (entries (u32le v (+ package 12)))
         (programs (+ package (* 4 (aref v package))))
         (entry (loop for i below entries
                      for at = (+ package 16 (* 12 i))
                      when (and (zerop (aref v (+ at 1))) (= (aref v (+ at 2)) (char-code #\*)))
                        return at)))
    (unless (and (= (u32le v 0) 9) entry) (error "no main DMC program in ~a" *dmc-path*))
    (let ((h (+ programs (* 4 (u32le v (+ entry 4))))))
      (unless (and (= (u32le v h) #x40403E3E) (= (aref v (+ h 5)) 3) (= (* 4 (aref v (+ h 4))) 256))
        (error "the main DMC header is not version 3"))
      (let ((count (u32le v (+ h 92))))
        (list :start (u32le v (+ h 20))
              :version (u32le v (+ h 16))
              :program (subseq v (+ h 256) (+ h 256 (* 4 (u32le v (+ h 12)))))
              :writes (loop for i below count
                            collect (cons (u32le v (+ h 96 (* 4 i))) (u32le v (+ h 176 (* 4 i))))))))))

(defun load-dmc ()
  (let ((dmc (main-dmc (read-file-octets *dmc-path*))))
    (dolist (gate '(#x4654C #x46550))
      (setf (reg gate) (logior (reg gate) (ash 1 12))))
    (dotimes (i 8)
      (setf (reg (+ +evt-ctl+ (* 4 i))) (logior (ash 2 16) (ash 1 8))
            (reg (+ +evt-htp+ (* 4 i))) 0))
    (let ((program (getf dmc :program)) (start (getf dmc :start)))
      (loop for i from 0 below (length program) by 4
            do (setf (reg (+ start i)) (u32le program i))))
    (loop for (address . value) in (getf dmc :writes)
          do (setf (reg address) value))
    (setf (reg +dc-state-debug+) (logior (reg +dc-state-debug+) 3))
    (list :version (getf dmc :version) :ssp (reg +ssp-base+))))

(defun allow-dc (level)
  (let ((value (ecase level (0 0) (5 1) (6 2))))
    (loop repeat 100
          do (setf (reg +dc-state-en+) (logior (logandc2 (reg +dc-state-en+) 3) value))
             (when (= (logand (reg +dc-state-en+) 3) value) (return value))
             (sleep 0.001))))
