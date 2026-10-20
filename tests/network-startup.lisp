(in-package #:darterfly/test)

(def-suite network-startup :in host)
(in-suite network-startup)

;; These fixtures change globals because service threads must share the same
;; publication slots. Restore the host's network state after joining every thread.
(defun call-with-startup-fixture (function)
  (let* ((symbols '(darterfly/net:*interface* darterfly/net::*configuration*
                    darterfly/net::*tcp-timer* darterfly/net::*listeners*
                    darterfly/nrepl::*thread* darterfly/nrepl::*listener*
                    darterfly/nrepl::*key* darterfly/nrepl:*port* bsd::*activities*))
         (saved (mapcar #'symbol-value symbols))
         (created nil) (lock (sb-thread:make-mutex)))
    (unwind-protect
         (progn
           (mapc (lambda (s v) (set s v)) symbols
                 (list nil nil nil (make-hash-table) nil nil "startup-test" 4011 nil))
           (sb-ext:without-package-locks
             (sb-int:encapsulate
              'sb-thread:make-thread 'startup-fixture
              (lambda (original function &rest args)
                (let ((thread (apply original function args)))
                  (sb-thread:with-mutex (lock) (push thread created))
                  thread))))
           (funcall function))
      (sb-ext:without-package-locks
        (sb-int:unencapsulate 'sb-thread:make-thread 'startup-fixture))
      (dolist (thread created)
        (when (sb-thread:thread-alive-p thread) (sb-thread:terminate-thread thread))
        (sb-thread:join-thread thread :default nil :timeout 3))
      (mapc (lambda (s v) (set s v)) symbols saved))))

(defmacro with-startup-fixture (&body body)
  `(call-with-startup-fixture (lambda () ,@body)))

;; Hold the first resource creation until the second caller has started. A second
;; creation reaches SECOND on the buggy implementation; the fixed caller waits
;; for the owner instead. Always release the gate, including failed assertions.
(defun race-startup (symbol select start)
  (let ((first (sb-thread:make-semaphore)) (second (sb-thread:make-semaphore))
        (release (sb-thread:make-semaphore)) (entered (sb-thread:make-semaphore))
        (lock (sb-thread:make-mutex)) (count 0) (workers nil))
    (unwind-protect
         (progn
           (sb-ext:without-package-locks
             (sb-int:encapsulate
              symbol 'startup-gate
              (lambda (original &rest args)
                (when (apply select args)
                  (let ((number (sb-thread:with-mutex (lock) (incf count))))
                    (if (= number 1)
                        (progn (sb-thread:signal-semaphore first)
                               (unless (sb-thread:wait-on-semaphore release :timeout 5)
                                 (error "startup gate timed out")))
                        (sb-thread:signal-semaphore second))))
                (apply original args))))
           (push (sb-thread:make-thread start :name "first startup") workers)
           (is (sb-thread:wait-on-semaphore first :timeout 3))
           (push (sb-thread:make-thread
                  (lambda () (sb-thread:signal-semaphore entered) (funcall start))
                  :name "second startup") workers)
           (is (sb-thread:wait-on-semaphore entered :timeout 3))
           (sb-thread:wait-on-semaphore second :timeout .2))
      (sb-thread:signal-semaphore release)
      (dolist (thread workers) (sb-thread:join-thread thread :timeout 6))
      (sb-ext:without-package-locks (sb-int:unencapsulate symbol 'startup-gate)))
    (is (= 1 count) "only one caller creates the shared service")))

(test concurrent-tcp-users-share-one-timer
  (with-startup-fixture
    (race-startup 'sb-thread:make-thread
                  (lambda (fn &key name &allow-other-keys)
                    (declare (ignore fn)) (equal name "tcp timer"))
                  #'darterfly/net::ensure-tcp-timer)
    (is (sb-thread:thread-alive-p darterfly/net::*tcp-timer*))))

(test a-dead-tcp-timer-is-replaced
  (with-startup-fixture
    (darterfly/net::ensure-tcp-timer)
    (let ((old darterfly/net::*tcp-timer*))
      (sb-thread:terminate-thread old)
      (sb-thread:join-thread old :default nil)
      (darterfly/net::ensure-tcp-timer)
      (is (not (eq old darterfly/net::*tcp-timer*)))
      (is (sb-thread:thread-alive-p darterfly/net::*tcp-timer*)))))

(test concurrent-nrepl-starts-share-one-listener
  (with-startup-fixture
    (setf darterfly/net:*interface* (darterfly/net::make-interface))
    (race-startup 'darterfly/net:tcp-listen (constantly t)
                  (lambda () (darterfly/nrepl::start-server 4011 "startup-test")))
    (is (eq darterfly/nrepl::*listener* (gethash 4011 darterfly/net::*listeners*)))
    (is (darterfly/nrepl:running-p))
    (darterfly/nrepl:stop)
    (is (null (gethash 4011 darterfly/net::*listeners*)))
    (is (not (darterfly/nrepl:running-p)))))

(test failed-nrepl-start-does-not-leave-a-bound-port
  (with-startup-fixture
    (setf darterfly/net:*interface* (darterfly/net::make-interface))
    (unwind-protect
         (progn
           (sb-ext:without-package-locks
             (sb-int:encapsulate
              'sb-thread:make-thread 'startup-failure
              (lambda (original fn &rest args &key name &allow-other-keys)
                (when (equal name "nrepl listener") (error "injected startup failure"))
                (apply original fn args))))
           (signals error (darterfly/nrepl::start-server 4011 "startup-test"))
           (is (null (gethash 4011 darterfly/net::*listeners*)))
           (is (null darterfly/nrepl::*listener*)))
      (sb-ext:without-package-locks
        (sb-int:unencapsulate 'sb-thread:make-thread 'startup-failure)))
    (darterfly/nrepl::start-server 4011 "startup-test")
    (is (darterfly/nrepl:running-p))))

(test concurrent-network-starts-publish-one-interface
  (with-startup-fixture
    (let ((arrived (sb-thread:make-semaphore)) (release (sb-thread:make-semaphore))
          (workers nil))
      (unwind-protect
           (progn
             (sb-int:encapsulate
              'darterfly/devices:start-devices 'startup-devices
              (lambda (original) (declare (ignore original))
                (sb-thread:signal-semaphore arrived)
                (sb-thread:wait-on-semaphore release :timeout 3)))
             (sb-int:encapsulate 'darterfly/devices:find-entries 'startup-devices
                                 (lambda (&rest args) (declare (ignore args)) nil))
             (dotimes (i 2)
               (push (sb-thread:make-thread #'darterfly/net:start-network) workers))
             ;; Both callers have passed the original early check before either
             ;; can publish. Hold the constructor too to expose replacement.
             (is (sb-thread:wait-on-semaphore arrived :timeout 2))
             (is (sb-thread:wait-on-semaphore arrived :timeout 2))
             (sb-int:encapsulate 'darterfly/net::make-interface 'startup-constructor
                                 (lambda (original &rest args)
                                   (sleep .05) (apply original args)))
             (sb-thread:signal-semaphore release 2)
             (let ((interfaces (mapcar (lambda (x) (sb-thread:join-thread x :timeout 4)) workers)))
               (is (eq (first interfaces) (second interfaces)))
               (is (eq (first interfaces) darterfly/net:*interface*))))
        (sb-thread:signal-semaphore release 2)
        (dolist (x workers) (sb-thread:join-thread x :timeout 4 :default nil))
        (sb-int:unencapsulate 'darterfly/devices:start-devices 'startup-devices)
        (sb-int:unencapsulate 'darterfly/devices:find-entries 'startup-devices)
        (sb-int:unencapsulate 'darterfly/net::make-interface 'startup-constructor)))))

(test startup-errors-do-not-park-with-service-locks-held
  (sb-thread:with-mutex (darterfly/net::*start-lock*)
    (is (member "network start" (bsd::system-locks-held) :test #'equal)))
  (sb-thread:with-mutex (darterfly/nrepl::*server-lock*)
    (is (member "nrepl server" (bsd::system-locks-held) :test #'equal))))
