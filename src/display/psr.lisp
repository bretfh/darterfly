(in-package #:darterfly/display)

(defconstant +ddi-func-ctl-a+ #x60400)
(defconstant +psr-ctl-a+ #x60800)
(defconstant +psr-debug-a+ #x60860)
(defconstant +cursor-surface-live-a+ #x700AC)

(defvar *psr* nil)

(pushnew 'forget-psr sb-ext:*save-hooks*)

(defun forget-psr () (setf *psr* nil))

(defun edp-on-transcoder-a-p ()
  (let ((ctl (reg +ddi-func-ctl-a+)))
    (and (logbitp 31 ctl) (= (ldb (byte 4 27) ctl) 1) (= (ldb (byte 3 24) ctl) 2))))

(defun enable-psr ()
  (unless (edp-on-transcoder-a-p) (error "transcoder A is not driving the eDP panel"))
  (when (zerop (first (aux-read #x070 1))) (error "the panel has no self-refresh"))
  (aux-write #x600 1)
  (aux-write #x170 (logior 1 4))
  (setf (reg +psr-debug-a+) (logior (ash 1 25) (ash 1 26) (ash 1 27) (ash 1 28)))
  (setf (reg +psr-ctl-a+) (logior (logand (reg +psr-ctl-a+) (ash 1 29))
                                  (ash 1 31) (ash #x1f 20) (ash 3 6) (ash 1 10) 6))
  (setf *psr* t))

(defun disable-psr ()
  (setf *psr* nil)
  (setf (reg +psr-ctl-a+) (logandc2 (reg +psr-ctl-a+) (ash 1 31))))

(defun screen-changed ()
  (when *psr* (setf (reg +cursor-surface-live-a+) 0)))

(defun start-display ()
  (when (graphics)
    (load-dmc)
    (enable-psr)))
