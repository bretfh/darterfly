;;;; Installed application entry, independent of the qualification harness.
(in-package #:cl-user)
(defvar *nyxt-runtime-load* nil)
(let ((*nyxt-runtime-load* t)) (load "/usr/lib/nyxt/nyxt-load.lisp"))
(load "/usr/lib/nyxt/nyxt-wire.lisp")
(load "/usr/lib/nyxt/nyxt-windows.lisp")
(load "/usr/lib/nyxt/nyxt-renderer.lisp")
(defpackage #:darterfly/nyxt-application
  (:use #:cl) (:export #:run #:activate))
(in-package #:darterfly/nyxt-application)
(defun activate (urls)
  (let ((window (and nyxt:*browser* (nyxt:current-window))))
    (when window
      (nyxt/renderer/wpe::window-call 106 (nyxt/renderer/wpe::native-id window))
      (when urls
        (nyxt:ffi-buffer-load (nyxt:current-buffer) (quri:uri (first urls)))))))
(defun run (argv)
  ;; The shipped trust store is used unless the user supplies an override.
  (unless (uiop:getenv "SSL_CERT_FILE")
    (sb-posix:setenv "SSL_CERT_FILE" "/etc/ssl/certs/ca-certificates.crt" 1))
  (sb-posix:setenv "GIO_USE_TLS" "openssl" 1)
  (let ((urls (or (rest argv) '("about:blank"))))
    (unwind-protect
        (progn
          (nyxt/renderer/wpe:launch urls)
          ;; Upstream startup continues asynchronously. Report readiness only
          ;; after a real view has reached the world's WindowServer client.
          (loop repeat 2400
                when nyxt/renderer/wpe::*failure*
                  do (error "Nyxt startup failed: ~a" nyxt/renderer/wpe::*failure*)
                when (and (lparallel:fulfilledp
                            (slot-value nyxt:*browser* 'nyxt::startup-promise))
                          (nyxt:current-window) (nyxt:current-buffer)
                          (plusp (nyxt/renderer/wpe::native-frame-count
                                   (nyxt:current-buffer))))
                  return t
                do (sleep .05)
                finally (error "Nyxt did not present a window"))
          (format t "~&[NYXT APPLICATION READY]~%") (finish-output)
          (loop until (and nyxt/renderer/wpe::*closing*
                           (null nyxt/renderer/wpe::*engine-process*)
                           (null nyxt:*browser*)
                           nyxt/renderer/wpe::*uninstalled*)
                do (when nyxt/renderer/wpe::*failure*
                     (error "Nyxt renderer failed: ~a" nyxt/renderer/wpe::*failure*))
                   (sleep .1))
          0)
      (unless nyxt/renderer/wpe::*closing*
        (ignore-errors (nyxt:ffi-kill-browser nyxt:*browser*))))))
