(in-package #:cl-user)

(defun native-check (label ok)
  (format t "~&[NATIVE ~a ~a]~%" label (if ok "PASS" "FAIL"))
  (finish-output)
  ok)

(defun native-start (mode &optional port (path "/Users/darterfly/native-probe"))
  (darterfly/worlds:spawn-native
   path :argv (list path mode "tail") :envp '("NATIVE=yes") :port port))

(defun native-status (mode &optional (path "/Users/darterfly/native-probe"))
  (let ((world (native-start mode nil path)))
    (unwind-protect (darterfly/worlds:wait-native world :timeout 10)
      (ignore-errors (darterfly/worlds:stop world))
      (ignore-errors (darterfly/worlds:wait-native world :timeout 5)))))

(native-check "HOST-ELF" (eql (ash 37 8) (native-status "ok")))
(let* ((port (darterfly/worlds:make-port))
       (world (native-start "port" port)))
  (unwind-protect
       (multiple-value-bind (msg token sender)
           (darterfly/worlds:receive port :timeout 5)
         (darterfly/worlds:reply token "pong")
         (native-check "PORT"
                       (and (= sender world) (equalp msg #(112 105 110 103))
                            (eql (ash 37 8)
                                 (darterfly/worlds:wait-native world
                                                             :timeout 5)))))
    (ignore-errors (darterfly/worlds:stop world))
    (ignore-errors (darterfly/worlds:wait-native world :timeout 5))))
(native-check "ZERO-EXIT" (eql 0 (native-status "zero")))
(native-check "ILLEGAL" (eql 4 (native-status "illegal")))
(native-check "FAULT" (eql 11 (native-status "fault")))
(native-check "TEXT" (eql 11 (native-status "x")))
(native-check "STACK" (eql 11 (native-status "nx")))
(let ((world (native-start "loop")))
  (unwind-protect
       (progn
         (native-check "NOHANG"
                       (null (darterfly/worlds:wait-native world :nohang t)))
         (native-check "TIMEOUT"
                       (null (darterfly/worlds:wait-native world
                                                         :timeout 0.02)))
         (darterfly/worlds:stop world)
         (native-check "KILL"
                       (eql 9 (darterfly/worlds:wait-native world :timeout 5)))
         (native-check "DOUBLE-WAIT"
                       (handler-case
                           (progn (darterfly/worlds:wait-native world) nil)
                         (darterfly/worlds:world-error (e)
                           (= 10 (darterfly/worlds::world-error-code e))))))
    (ignore-errors (darterfly/worlds:stop world))
    (ignore-errors (darterfly/worlds:wait-native world :timeout 5))))

;; Malformed file offsets, overflow, wrong architecture, dynamic images, invalid TLS,
;; executable stacks, W+X, overlapping pages and non-executable entry points.
(let* ((file (darterfly/run::read-octets "/Users/darterfly/native-probe"))
       (ph (darterfly/link::u file 32 8))
       (count (darterfly/link::u file 56 2))
       (loads (loop for i below count for h = (+ ph (* i 56))
                    when (= 1 (darterfly/link::u file h 4)) collect h))
       (first (first loads))
       (second (second loads))
       (bad (list (list 0 0 4) (list 18 3 2) (list 32 -1 8)
                  (list 56 65535 2) (list (+ first 8) -1 8)
                  (list (+ first 40) -1 8) (list (+ first 4) 7 4)
                  (list (+ first 48) 3 8) (list 24 #x1000 8)
                  (list first 3 4) (list first 2 4) (list first 7 4)
                  (list (+ second 16)
                        (darterfly/link::u file (+ first 16) 8) 8))))
  (native-check
   "BAD-ELF"
   (every
    (lambda (mutation)
      (let ((copy (copy-seq file)))
        (apply #'darterfly/link::put copy mutation)
        (with-open-file (s "/tmp/bad-native" :direction :output
                            :element-type '(unsigned-byte 8)
                            :if-exists :supersede)
          (write-sequence copy s))
        (handler-case
            (let ((w (native-start "ok" nil "/tmp/bad-native")))
              (darterfly/worlds:stop w)
              (darterfly/worlds:wait-native w :timeout 5)
              nil)
          (darterfly/worlds:world-error (e)
            (= 8 (darterfly/worlds::world-error-code e)))))) bad)))

(native-check
 "REBUILD"
 (and (darterfly/cc:compile-c "/Users/darterfly/native-start.S" "/tmp/native-start.o"
                             :compat nil)
      (darterfly/cc:compile-c "/Users/darterfly/native-probe.c" "/tmp/native-probe.o"
                             :compat nil)
      (let* ((objects
               (loop for name in '("/tmp/native-start.o" "/tmp/native-probe.o")
                     collect (darterfly/link:read-object
                              (darterfly/run::read-octets name)
                              name :user)))
             (exe (darterfly/link:link-native objects)))
        (with-open-file (s "/tmp/native-rebuilt" :direction :output
                          :element-type '(unsigned-byte 8)
                          :if-exists :supersede)
          (write-sequence exe s))
        t)))
(native-check "REBUILT-ELF"
              (eql (ash 37 8) (native-status "ok" "/tmp/native-rebuilt")))


;; Exit metadata is bounded, even when the supervisor forgets to wait.
(let ((children nil))
  (unwind-protect
       (progn
         (dotimes (i 128) (push (native-start "ok") children))
         (native-check
          "STATUS-LIMIT"
          (handler-case
              (progn (push (native-start "ok") children) nil)
            (darterfly/worlds:world-error (e)
              (= 11 (darterfly/worlds::world-error-code e)))))
         (native-check
          "REAP-ALL"
          (every (lambda (w)
                   (eql (ash 37 8)
                        (darterfly/worlds:wait-native w :timeout 5))) children)))
    (dolist (w children)
      (ignore-errors (darterfly/worlds:stop w))
      (ignore-errors (darterfly/worlds:wait-native w :timeout 5)))))

;; More cycles than the exit table has slots. Hold buffers fixed so this
;; measures child pages, rather than newly committed parent Lisp heap pages.
(let* ((file (darterfly/run::read-octets "/Users/darterfly/native-probe"))
       (stack (darterfly/worlds::native-stack
               '("probe" "ok" "tail") '("NATIVE=yes"))))
  (darterfly/worlds::with-octets (f file)
    (darterfly/worlds::with-octets (s stack)
      (flet ((cycle ()
               (let ((w (darterfly/worlds::machdep
                         80 f (length file) s (length stack))))
                 (eql (ash 37 8)
                      (darterfly/worlds:wait-native w :timeout 5)))))
        (dotimes (i 140) (cycle))
        (let* ((before (darterfly/worlds:free-pages))
               (ok (loop repeat 140 always (cycle)))
               (lost (- before (darterfly/worlds:free-pages))))
          (format t "~&[NATIVE RECLAIM pages ~d]~%" lost)
          (native-check "RECLAIM" (and ok (< lost 32))))))))
(native-check "ALIVE" (= 42 (+ 20 22)))
