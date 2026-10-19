(defpackage #:darterfly/audio
  (:use #:cl)
  (:export #:audio-device #:audio-devices #:default-output-device
           #:open-output #:output-write #:output-close #:output-running-p
           #:device-volume #:device-mute #:device-outputs #:device-status
           #:play #:play-tone #:volume #:mute #:audio-status #:start-audio))
(in-package #:darterfly/audio)

(devices:define-device-class audio-device "AudioDevice" (devices:device) ())

(defvar *audio-devices* nil)

(pushnew 'forget-audio-devices sb-ext:*save-hooks*)

(defun forget-audio-devices () (setf *audio-devices* nil))

(defun audio-devices () *audio-devices*)

(defun register-audio-device (device)
  (setf *audio-devices* (append (remove device *audio-devices*) (list device)))
  device)

(defun default-output-device () (first *audio-devices*))

(defgeneric open-output (device &key rate channels bits))
(defgeneric output-write (output octets &key start end))
(defgeneric output-close (output))
(defgeneric output-running-p (output))
(defgeneric device-volume (device))
(defgeneric (setf device-volume) (volume device))
(defgeneric device-mute (device))
(defgeneric (setf device-mute) (mute device))
(defgeneric device-outputs (device))
(defgeneric device-status (device))
