(defpackage #:darterfly/bench
  (:use #:cl)
  (:export #:run #:*benchmarks*))
(in-package #:darterfly/bench)

(defvar *benchmarks* nil)

(defmacro define-benchmark (name (unit &key (lower-is-better t)) &body body)
  `(progn
     (setf *benchmarks* (append (remove ',name *benchmarks* :key #'first)
                                (list (list ',name ,unit ,lower-is-better (lambda () ,@body)))))
     ',name))

(defun now-us () (/ (get-internal-real-time) (/ internal-time-units-per-second 1000000)))

(defmacro elapsed-us (&body body)
  `(let ((start (now-us))) ,@body (- (now-us) start)))

(defun best-of (n thunk)
  (loop repeat n minimize (funcall thunk)))

(defun fixnum-loop (n)
  (declare (fixnum n) (optimize speed))
  (let ((s 0))
    (declare (fixnum s))
    (dotimes (i n s) (setf s (logand (+ s (* i i)) #xffffff)))))

(defun fib (n)
  (let ((a 0) (b 1))
    (dotimes (i n a) (psetf a b b (+ a b)))))

(define-benchmark fixnum-loop-ms ("ms")
  (/ (best-of 3 (lambda () (elapsed-us (fixnum-loop 100000000)))) 1000.0))

(define-benchmark bignum-fib-ms ("ms")
  (/ (best-of 3 (lambda () (elapsed-us (fib 50000)))) 1000.0))

(define-benchmark allocate-ms ("ms")
  (/ (best-of 3 (lambda () (elapsed-us (let ((keep nil))
                                         (dotimes (i 1000000) (setf keep (cons i keep)) (when (zerop (mod i 1000)) (setf keep nil)))))))
     1000.0))

(define-benchmark full-gc-ms ("ms")
  (/ (best-of 3 (lambda () (elapsed-us (sb-ext:gc :full t)))) 1000.0))

(define-benchmark thread-us ("us")
  (/ (best-of 3 (lambda () (elapsed-us (dotimes (i 200) (sb-thread:join-thread (sb-thread:make-thread (lambda () 1)))))))
     200.0))

(darterfly/bsd:define-program "true" (argv envp) 0)

(defparameter *true* "/usr/bin/true")

(define-benchmark spawn-us ("us")
  (unless (probe-file *true*)
    (with-open-file (s *true* :direction :output :if-exists :supersede) (format s "#!darterfly true~%"))
    (darterfly/vfs:vnop-setattr (darterfly/vfs::namei *true*) :mode #o755))
  (/ (best-of 3 (lambda () (elapsed-us (dotimes (i 50) (darterfly/bsd:wait4 (darterfly/bsd:posix-spawn *true* (list "true") nil))))))
     50.0))

(define-benchmark message-us ("us")
  (let ((port (darterfly/mach:mach-port-allocate darterfly/mach:*task* :receive)))
    (darterfly/mach:mach-port-insert-right darterfly/mach:*task* port port :make-send)
    (prog1 (/ (best-of 3 (lambda ()
                           (elapsed-us (dotimes (i 5000)
                                         (darterfly/mach:mach-msg-send (darterfly/mach:make-message :remote-port port :body i))
                                         (darterfly/mach:mach-msg-receive port)))))
              5000.0)
      (darterfly/mach:mach-port-destroy darterfly/mach:*task* port))))

(defparameter *scratch* "/tmp/bench.bin")

(define-benchmark disk-write-mb-s ("MB/s" :lower-is-better nil)
  (let ((block (make-array (* 1024 1024) :element-type '(unsigned-byte 8) :initial-element 7))
        (path "/Users/bench.bin"))
    (prog1 (/ 32.0 (/ (elapsed-us (with-open-file (s path :direction :output :element-type '(unsigned-byte 8) :if-exists :supersede)
                                    (dotimes (i 32) (write-sequence block s)))
                                  (darterfly/vfs:vfs-sync))
                      1000000.0))
      (ignore-errors (delete-file path)) (darterfly/vfs:vfs-sync))))

(define-benchmark compile-ms ("ms")
  (let ((file "/usr/src/darterfly/src/apfs/write.lisp"))
    (when (probe-file file)
      (/ (best-of 3 (lambda () (elapsed-us (let ((*error-output* (make-broadcast-stream)) (*standard-output* (make-broadcast-stream)))
                                             (compile-file file :output-file "/tmp/bench.fasl")))))
         1000.0))))

(define-benchmark full-frame-ms ("ms")
  (when darterfly/windowserver::*framebuffer*
    (/ (best-of 3 (lambda () (elapsed-us (sb-thread:with-recursive-lock (darterfly/windowserver::*lock*)
                                           (darterfly/windowserver::damage-all)
                                           (darterfly/windowserver::render)))))
       1000.0)))

(defparameter *call-loop*
  (coerce #(187 208 7 0 0 184 41 0 0 0 191 1 0 0 0 72 190 0 8 0 64 0 0 0 0 186 4 0 0 0 73 186 0 9 0 64 0 0 0 0
            65 184 16 0 0 0 205 130 255 203 117 209 184 1 0 0 0 49 255 205 128 235 254)
          '(simple-array (unsigned-byte 8) (*))))

(defparameter *calls* 2000)

(defparameter *exit-at* 52)

(defun wait-gone (world)
  (loop :until (eq (darterfly/worlds:world-state world) :gone)))

(define-benchmark world-spawn-us ("us")
  (/ (best-of 3 (lambda () (elapsed-us (dotimes (i 20) (wait-gone (darterfly/worlds:spawn *call-loop* :entry *exit-at*))))))
     20.0))

(define-benchmark world-call-us ("us")
  (/ (best-of 3 (lambda ()
                  (let ((port (darterfly/worlds:make-port)))
                    (darterfly/worlds:spawn *call-loop* :port port)
                    (elapsed-us (dotimes (i *calls*)
                                  (multiple-value-bind (m token) (darterfly/worlds:receive port :timeout 5)
                                    (declare (ignore m))
                                    (darterfly/worlds:reply token "ok")))))))
     *calls*))

(defparameter *sbcl-core* "/usr/lib/sbcl/sbcl.core")

(define-benchmark world-run-ms ("ms")
  (when (probe-file *sbcl-core*)
    (/ (best-of 3 (lambda () (elapsed-us (darterfly/run:run-world *sbcl-core* (list "/System/Library/Kernels/kernel" "--core" "/System/Library/Kernels/darterfly.core"
                                                                                  "--no-sysinit" "--no-userinit" "--disable-debugger" "--eval" "(+ 1 2)" "--quit")
                                                                  :cwd "/"))))
       1000.0)))

(define-benchmark heap-check-ms ("ms")
  (/ (best-of 3 (lambda () (elapsed-us (darterfly/install::heap-errors)))) 1000.0))

(defun memory ()
  (list :free-mb (round (* 4096 (darterfly/worlds:free-pages)) 1048576)
        :heap-mb (round (sb-kernel:dynamic-usage) 1048576)
        :kernel-threads (hash-table-count (darterfly/stats::thread-times))
        :lisp-threads (length (sb-thread:list-all-threads))))

(defun idle ()
  (let ((s (darterfly/stats:sample 5)))
    (list :idle-cpu-percent (/ (round (* 10 (/ (reduce #'+ (getf s :cpu-busy)) (max 1 (length (getf s :cpu-busy)))))) 10.0)
          :idle-switches-s (getf s :switches-per-s)
          :idle-interrupts-s (reduce #'+ (getf s :interrupts-per-s) :key #'cdr)
          :idle-package-w (getf s :package-w)
          :idle-battery-ma (getf s :battery-ma))))

(defun run (&key (only nil))
  (append
   (loop for (name unit lower thunk) in *benchmarks*
         when (or (null only) (member name only :test #'string-equal))
           collect (list (intern (symbol-name name) :keyword) (handler-case (funcall thunk) (error (e) (princ-to-string e))) unit lower))
   (unless only
     (loop for (key value) on (memory) by #'cddr
           collect (list key value (if (search "-MB" (symbol-name key)) "MB" "") t)))
   (unless only
     (loop for (key value) on (idle) by #'cddr
           collect (list key value
                         (cond ((search "PERCENT" (symbol-name key)) "%") ((search "-W" (symbol-name key)) "W")
                               ((search "-MA" (symbol-name key)) "mA") (t "/s"))
                         t)))))
