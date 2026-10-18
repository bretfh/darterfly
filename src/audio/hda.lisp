(defpackage #:darterfly/audio
  (:use #:cl)
  (:export #:start-audio #:write-pcm #:play-tone #:volume #:mute #:audio-status #:output-pin))
(in-package #:darterfly/audio)

(defvar *controller* nil)
(defvar *registers* nil)
(defvar *verb-lock* (sb-thread:make-mutex :name "hda verbs"))

(pushnew 'forget-controller sb-ext:*save-hooks*)

(defun forget-controller () (setf *controller* nil *registers* nil))

(defun controller ()
  (or *controller*
      (setf *controller*
            (find-if (lambda (d) (and (= (devices:config-read-16 d 0) #x8086)
                                      (= (ash (devices:config-read-32 d 8) -8) #x040300)))
                     (devices:find-entries 'devices:pci-node)))))

(defun registers ()
  (or *registers* (setf *registers* (devices:ml-io-map (devices::bar-address (controller) 0) #x4000))))

(defun reg (offset width) (devices:mmio-read (+ (registers) offset) width))
(defun (setf reg) (value offset width) (devices:mmio-write (+ (registers) offset) width value) value)

(defun wait-for (what test &optional (seconds 0.1))
  (let ((deadline (+ (get-internal-real-time) (* seconds internal-time-units-per-second))))
    (loop until (funcall test)
          do (when (> (get-internal-real-time) deadline) (error "hda: timed out waiting for ~a" what))
             (sleep 0.0001))))

(defun power-state (d)
  (let ((pm (devices:find-pci-capability d 1)))
    (ldb (byte 2 0) (devices:config-read-16 d (+ pm 4)))))

(defun (setf power-state) (state d)
  (let* ((pm (devices:find-pci-capability d 1)) (csr (devices:config-read-16 d (+ pm 4))))
    (devices:config-write-16 d (+ pm 4) (logior (logand csr (lognot #x8003)) state))
    (sleep 0.01)
    state))

(defun reset-controller ()
  (let ((d (controller)))
    (unless (zerop (power-state d)) (setf (power-state d) 0))
    (devices:config-write-16 d #x78 (logandc2 (devices:config-read-16 d #x78) (ash 1 11)))
    (devices:config-write-8 d #x44 (logandc2 (devices:config-read-8 d #x44) 7))
    (setf (reg #x08 32) (logandc2 (reg #x08 32) 1))
    (wait-for "the controller to enter reset" (lambda () (zerop (logand (reg #x08 32) 1))))
    (sleep 0.001)
    (setf (reg #x08 32) (logior (reg #x08 32) 1))
    (wait-for "the controller to leave reset" (lambda () (logbitp 0 (reg #x08 32))))
    (sleep 0.002)
    (reg #x0E 16)))

(defun verb (cad nid verb payload)
  (let ((command (if (> verb #xF)
                     (logior (ash cad 28) (ash nid 20) (ash verb 8) payload)
                     (logior (ash cad 28) (ash nid 20) (ash verb 16) payload))))
    (sb-thread:with-mutex (*verb-lock*)
      (wait-for "the command interface" (lambda () (not (logbitp 0 (reg #x68 16)))))
      (setf (reg #x68 16) 2)
      (setf (reg #x60 32) command)
      (setf (reg #x68 16) 1)
      (wait-for "a codec response" (lambda () (logbitp 1 (reg #x68 16))))
      (reg #x64 32))))

(defun param (cad nid p) (verb cad nid #xF00 p))

(defun input-streams () (ldb (byte 4 8) (reg 0 16)))
