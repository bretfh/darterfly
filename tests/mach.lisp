(in-package #:finch/test)

(def-suite mach :in all)
(in-suite mach)

(defmacro in-task ((&optional (name "test")) &body body)
  `(let ((mach:*task* (mach:make-task ,name)))
     ,@body))

(defun port ()
  (let ((name (mach:mach-port-allocate mach:*task* :receive)))
    (mach:mach-port-insert-right mach:*task* name name :make-send)
    name))

(defun spawn (task fn)
  (sb-thread:make-thread (lambda () (let ((mach:*task* task)) (funcall fn)))))

(test names-and-rights
  (in-task ()
    (let ((name (mach:mach-port-allocate mach:*task* :receive)))
      (is (equal '(:receive) (mach:mach-port-type mach:*task* name)))
      (is (= 3 (ldb (byte 8 0) name)))
      (mach:mach-port-insert-right mach:*task* name name :make-send)
      (is (null (set-exclusive-or '(:receive :send) (mach:mach-port-type mach:*task* name))))
      (mach:mach-port-insert-right mach:*task* name name :make-send)
      (is (= 2 (mach:mach-port-get-refs mach:*task* name :send)))
      (mach:mach-port-deallocate mach:*task* name)
      (mach:mach-port-deallocate mach:*task* name)
      (is (equal '(:receive) (mach:mach-port-type mach:*task* name)))
      (fails-with :kern-invalid-right (mach:mach-port-deallocate mach:*task* name))
      (fails-with :kern-invalid-name (mach:mach-port-type mach:*task* (+ name #x100000))))))

(test kern-return-codes
  (is (= #x10004003 (mach:kern-return-code :mach-rcv-timed-out)))
  (is (= #x10000003 (mach:kern-return-code :mach-send-invalid-dest)))
  (is (= 15 (mach:kern-return-code :kern-invalid-name))))

(test round-trip
  (in-task ()
    (let ((p (port))
          (reply (mach:mach-port-allocate mach:*task* :receive)))
      (mach:mach-msg-send (mach:make-message :remote-port p :local-port reply
                                             :id 1000 :body '(:hello "world")))
      (let ((m (mach:mach-msg-receive p :timeout 100)))
        (is (= 1000 (mach:msgh-id m)))
        (is (equal '(:hello "world") (mach:msgh-body m)))
        (is (= p (mach:msgh-local-port m)))
        (is (eq :move-send (mach:msgh-local-disposition m)))
        (is (eq :move-send-once (mach:msgh-remote-disposition m)))
        (is (equal '(:send-once) (mach:mach-port-type mach:*task* (mach:msgh-remote-port m))))
        (mach:mach-msg-send (mach:make-message :remote-port (mach:msgh-remote-port m)
                                               :remote-disposition :move-send-once
                                               :id 1100 :body :done))
        (fails-with :kern-invalid-name
          (mach:mach-port-type mach:*task* (mach:msgh-remote-port m)))
        (let ((answer (mach:mach-msg-receive reply :timeout 100)))
          (is (= 1100 (mach:msgh-id answer)))
          (is (eq :move-send-once (mach:msgh-local-disposition answer))))))))

(test across-tasks
  (let* ((server (mach:make-task "server"))
         (client (mach:make-task "client"))
         (service (let ((mach:*task* server)) (port)))
         (got nil))
    (let ((mach:*task* server))
      (mach:mach-port-insert-right client #x1003 service :copy-send))
    (is (equal '(:send) (mach:mach-port-type client #x1003)))
    (let ((thread (spawn server (lambda () (setf got (mach:mach-msg-receive service :timeout 2000))))))
      (spawn client (lambda () (mach:mach-msg-send (mach:make-message :remote-port #x1003 :id 7 :body 42))))
      (sb-thread:join-thread thread))
    (is (= 7 (mach:msgh-id got)))
    (is (= 42 (mach:msgh-body got)))
    (is (= service (mach:msgh-local-port got)))))

(test send-rights-coalesce
  (let* ((a (mach:make-task "a"))
         (b (mach:make-task "b"))
         (pa (let ((mach:*task* a)) (port)))
         (pb (let ((mach:*task* b)) (port))))
    (let ((mach:*task* b))
      (mach:mach-port-insert-right a #x5003 pb :copy-send))
    (let ((mach:*task* a))
      (dotimes (i 2)
        (mach:mach-msg-send (mach:make-message :remote-port #x5003 :id i
                                               :ports (list (cons pa :make-send))))))
    (let ((mach:*task* b))
      (let ((n1 (car (first (mach:msgh-ports (mach:mach-msg-receive pb :timeout 100)))))
            (n2 (car (first (mach:msgh-ports (mach:mach-msg-receive pb :timeout 100))))))
        (is (= n1 n2))
        (is (= 2 (mach:mach-port-get-refs b n1 :send)))))))

(test queue-limit
  (in-task ()
    (let ((p (port)))
      (dotimes (i mach:+mach-port-qlimit-default+)
        (mach:mach-msg-send (mach:make-message :remote-port p :id i)))
      (fails-with :mach-send-timed-out
        (mach:mach-msg-send (mach:make-message :remote-port p :id 99) :timeout 20))
      (is (= 0 (mach:msgh-id (mach:mach-msg-receive p :timeout 0))))
      (mach:mach-msg-send (mach:make-message :remote-port p :id 5) :timeout 20)
      (is (equal '(1 2 3 4 5)
                 (loop :repeat 5 :collect (mach:msgh-id (mach:mach-msg-receive p :timeout 0))))))))

(test send-once-passes-the-limit
  (in-task ()
    (let ((p (port)))
      (dotimes (i mach:+mach-port-qlimit-default+)
        (mach:mach-msg-send (mach:make-message :remote-port p :id i)))
      (mach:mach-msg-send (mach:make-message :remote-port p :remote-disposition :make-send-once
                                             :id 99)
                          :timeout 0)
      (is (= 6 (loop :for n :from 0
                     :while (handler-case (mach:mach-msg-receive p :timeout 0)
                              (mach:kern-return () nil))
                     :finally (return n)))))))

(test receive-timeout
  (in-task ()
    (let ((p (port)))
      (fails-with :mach-rcv-timed-out (mach:mach-msg-receive p :timeout 0))
      (fails-with :mach-rcv-timed-out (mach:mach-msg-receive p :timeout 20))
      (fails-with :mach-rcv-invalid-name (mach:mach-msg-receive #x7777703)))))

(test dead-names
  (let* ((server (mach:make-task "server"))
         (client (mach:make-task "client"))
         (service (let ((mach:*task* server)) (port))))
    (let ((mach:*task* server))
      (mach:mach-port-insert-right client #x2003 service :make-send)
      (mach:mach-port-mod-refs server service :receive -1))
    (is (equal '(:dead-name) (mach:mach-port-type client #x2003)))
    (is (equal '(:dead-name) (mach:mach-port-type server service)))
    (let ((mach:*task* client))
      (fails-with :mach-send-invalid-dest
        (mach:mach-msg-send (mach:make-message :remote-port #x2003))))
    (mach:mach-port-deallocate client #x2003)
    (fails-with :kern-invalid-name (mach:mach-port-type client #x2003))))

(test receiver-wakes-when-the-port-dies
  (in-task ()
    (let* ((name (mach:mach-port-allocate mach:*task* :receive))
           (outcome nil)
           (thread (spawn mach:*task*
                          (lambda ()
                            (setf outcome (handler-case (mach:mach-msg-receive name :timeout 2000)
                                            (mach:kern-return (c) (mach:kern-return-name c))))))))
      (sleep 0.05)
      (mach:mach-port-destroy mach:*task* name)
      (sb-thread:join-thread thread)
      (is (eq :mach-rcv-port-died outcome)))))

(test port-sets
  (in-task ()
    (let ((a (port))
          (b (port))
          (set (mach:mach-port-allocate mach:*task* :port-set)))
      (mach:mach-port-move-member mach:*task* a set)
      (mach:mach-port-move-member mach:*task* b set)
      (fails-with :mach-rcv-timed-out (mach:mach-msg-receive a :timeout 0))
      (mach:mach-msg-send (mach:make-message :remote-port b :id 2))
      (let ((m (mach:mach-msg-receive set :timeout 100)))
        (is (= b (mach:msgh-local-port m)))
        (is (= 2 (mach:msgh-id m))))
      (mach:mach-port-move-member mach:*task* a nil)
      (fails-with :mach-rcv-timed-out (mach:mach-msg-receive a :timeout 0)))))

(test receive-rights-travel-with-their-queue
  (let* ((a (mach:make-task "a"))
         (b (mach:make-task "b"))
         (inbox (let ((mach:*task* b)) (port)))
         (carried (let ((mach:*task* a)) (port))))
    (let ((mach:*task* b))
      (mach:mach-port-insert-right a #x3003 inbox :copy-send))
    (let ((mach:*task* a))
      (mach:mach-msg-send (mach:make-message :remote-port carried :id 11 :body :queued))
      (mach:mach-port-deallocate a carried)
      (mach:mach-msg-send (mach:make-message :remote-port #x3003 :id 12
                                             :ports (list (cons carried :move-receive))))
      (fails-with :kern-invalid-name (mach:mach-port-type a carried)))
    (let ((mach:*task* b))
      (let* ((m (mach:mach-msg-receive inbox :timeout 100))
             (name (car (first (mach:msgh-ports m)))))
        (is (eq :move-receive (cdr (first (mach:msgh-ports m)))))
        (is (equal '(:receive) (mach:mach-port-type b name)))
        (let ((queued (mach:mach-msg-receive name :timeout 100)))
          (is (= 11 (mach:msgh-id queued)))
          (is (eq :queued (mach:msgh-body queued))))))))

(test failed-send-keeps-rights
  (in-task ()
    (let ((p (port))
          (r (mach:mach-port-allocate mach:*task* :receive)))
      (mach:mach-port-insert-right mach:*task* r r :make-send)
      (fails-with :mach-send-invalid-right
        (mach:mach-msg-send (mach:make-message :remote-port p
                                               :ports (list (cons r :move-send)
                                                            (cons #x9999903 :move-send)))))
      (is (= 1 (mach:mach-port-get-refs mach:*task* r :send)))
      (fails-with :mach-rcv-timed-out (mach:mach-msg-receive p :timeout 0)))))

(defun word (s) (intern (string-upcase s) :keyword))

(defun run-port-line (words vars)
  (flet ((name (w) (if (string= w "none") nil (gethash w vars)))
         (bind (w n) (setf (gethash w vars) n)))
    (destructuring-bind (op &rest args) words
      (let ((task mach:*task*))
        (handler-case
            (let ((more
                    (cond
                      ((string= op "allocate")
                       (bind (first args) (mach:mach-port-allocate task (word (second args))))
                       nil)
                      ((string= op "insert")
                       (mach:mach-port-insert-right task (name (first args)) (name (second args))
                                                    (word (third args)))
                       nil)
                      ((string= op "deallocate") (mach:mach-port-deallocate task (name (first args))) nil)
                      ((string= op "mod-refs")
                       (mach:mach-port-mod-refs task (name (first args)) (word (second args))
                                                (parse-integer (third args)))
                       nil)
                      ((string= op "destroy") (mach:mach-port-destroy task (name (first args))) nil)
                      ((string= op "move-member")
                       (mach:mach-port-move-member task (name (first args)) (name (second args)))
                       nil)
                      ((string= op "type")
                       (let ((rights (mach:mach-port-type task (name (first args)))))
                         (loop :for r :in '(:receive :send :send-once :port-set :dead-name)
                               :when (member r rights) :collect (string-downcase r))))
                      ((string= op "refs")
                       (list (mach:mach-port-get-refs task (name (first args)) (word (second args)))))
                      ((string= op "send")
                       (destructuring-bind (dest disposition reply reply-disposition id &rest carried) args
                         (mach:mach-msg-send
                          (mach:make-message :remote-port (name dest) :remote-disposition (word disposition)
                                             :local-port (name reply)
                                             :local-disposition (and (name reply) (word reply-disposition))
                                             :id (parse-integer id)
                                             :ports (loop :for (p d) :on carried :by #'cddr
                                                          :collect (cons (name p) (word d))))
                          :timeout 0))
                       nil)
                      ((string= op "receive")
                       (destructuring-bind (port reply &rest carried) args
                         (let ((m (mach:mach-msg-receive (name port) :timeout 0)))
                           (bind reply (mach:msgh-remote-port m))
                           (loop :for w :in carried :for (n) :in (mach:msgh-ports m) :do (bind w n))
                           (list* (mach:msgh-id m)
                                  (string-downcase (mach:msgh-local-disposition m))
                                  (string-downcase (or (mach:msgh-remote-disposition m) :none))
                                  (loop :for (nil . d) :in (mach:msgh-ports m)
                                        :collect (string-downcase d))))))
                      (t (error "no port op ~a" op)))))
              (format nil "0~{ ~a~}" more))
          (mach:kern-return (c) (format nil "~(~x~)" (mach:kern-return-code c))))))))

(test ports-match-xnu
  (let ((vars (make-hash-table :test 'equal))
        (lines (uiop:read-file-lines (asdf:system-relative-pathname :finch "tests/ports.txt"))))
    (is (< 100 (length lines)))
    (in-task ()
      (dolist (line lines)
        (destructuring-bind (script xnu) (uiop:split-string line :separator "|")
          (let* ((script (string-trim " " script))
                 (finch (run-port-line (uiop:split-string script :separator " ") vars)))
            (is (string= (string-trim " " xnu) finch) "~a: xnu ~a, finch ~a" script (string-trim " " xnu) finch)))))))
