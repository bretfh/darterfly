(defpackage #:darterfly/libsa
  (:use #:cl #:darterfly/low)
  (:shadow #:basename)
  (:export #:libsa-object))
(in-package #:darterfly/libsa)

(define-low __syscall (n a b c d e f)
  (let ((r (trap-errno #x80 n a b c d e f)))
    (if (signed< r 0)
        (progn (setf (mem :u32 (__errno_location)) (- 0 r)) (- 0 1))
        r)))

(define-low __machdep5 (n a b c d e)
  (trap-errno #x82 n a b c d e))

(define-low __machdep (n a b)
  (trap-errno #x82 n a b 0 0 0))

(defun libsa-object ()
  ;; Generate the provider from the same Low definitions being linked. DSOs
  ;; bind to this process's libsa; they never contain a second libc or TLS base.
  (let* ((*package* (find-package "DARTERFLY/LIBSA"))
         (names (sort (loop for f being the hash-values of darterfly/low::*functions*
                            when (string= (darterfly/low::low-function-package f)
                                          "DARTERFLY/LIBSA")
                            collect (darterfly/low::low-function-name f)) #'string<))
         (globals (loop for g being the hash-values of darterfly/low::*globals*
                        when (and (string= (darterfly/low::global-package g)
                                           "DARTERFLY/LIBSA")
                                  (darterfly/low::global-export g))
                        collect (darterfly/low::global-name g))))
    (eval `(define-low __libsa_export (name)
             ;; The compiler's C++ TLS registration entry shares libsa's
             ;; destructor list; no libc++abi copy is linked into the DSO.
             (when (= (the :u32 (strcmp name "__cxa_thread_atexit")) 0)
               (result (absolute "__cxa_thread_atexit_impl")))
             ,@(loop for n in (append names globals)
                     collect `(when (= (the :u32 (strcmp name ,n)) 0)
                                (result (absolute ,n))))
             0)))
  (package-object "DARTERFLY/LIBSA" :extra (list "va_next" "va_next_double")
    :routines (append (division-routines) (jump-routines)
                      (long-double-routines)
                      (list (strtold-routine) (wcstold-routine)
                            (long-double-bits-routine)))))
