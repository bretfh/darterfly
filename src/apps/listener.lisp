(in-package #:finch/apps)

(defparameter +listener-font+ "AdwaitaMono-Regular")

(defclass transcript-view (kit:view)
  ((lines :initform nil :accessor lines)
   (input :initform nil :accessor input)
   (file :initarg :file :reader transcript-file)
   (choose :initarg :choose :initform nil :accessor choose)))

(defun add-line (view text &optional object)
  (setf (lines view) (append (lines view) (list (cons (substitute #\Space #\Newline text) object))))
  (kit:needs-display view))

(defgeneric prompt (view))

(defmethod prompt ((view transcript-view))
  (format nil "* ~a" (input view)))

(defun shown-lines (view)
  (let ((rows (floor (- (kit:view-height view) 8) +line-height+))
        (all (append (lines view) (and (input view) (list (cons (prompt view) nil))))))
    (last all rows)))

(defmethod kit:draw ((view transcript-view) bitmap)
  (text:fill-bitmap bitmap 1.0 1.0 1.0 1.0)
  (let ((font (text:font +listener-font+ +terminal-size+))
        (shown (shown-lines view)))
    (loop :for (text . object) :in shown
          :for y :from (+ 4 +line-height+) :by +line-height+
          :do (if object
                  (text:draw-string bitmap font text 6 (- y 4) 0.11 0.35 0.75)
                  (text:draw-string bitmap font text 6 (- y 4) 0.0 0.0 0.0)))
    (with-open-file (s (transcript-file view) :direction :output :if-exists :supersede :if-does-not-exist :create)
      (format s "~{~a~%~}" (mapcar (lambda (line) (format nil "~:[ ~;>~] ~a" (cdr line) (car line))) shown)))))

(defmethod kit:mouse-down ((view transcript-view) x y)
  (declare (ignore x))
  (let ((line (nth (floor (- y 4) +line-height+) (shown-lines view))))
    (when (and line (cdr line) (choose view))
      (funcall (choose view) (cdr line))))
  t)

(defun printed (object)
  (let* ((*print-length* 12) (*print-level* 3) (*print-lines* 1)
         (s (prin1-to-string object)))
    (if (> (length s) 80) (concatenate 'string (subseq s 0 77) "...") s)))

(defgeneric parts (object))

(defmethod parts ((object t)) nil)

(defmethod parts ((object cons))
  (loop :for tail :on object
        :for i :from 0 :below 64
        :collect (cons (format nil "~d" i) (car tail))
        :unless (listp (cdr tail))
          :collect (cons "." (cdr tail)) :and :do (loop-finish)))

(defmethod parts ((object vector))
  (unless (stringp object)
    (loop :for x :across object :for i :from 0 :below 64 :collect (cons (format nil "~d" i) x))))

(defmethod parts ((object hash-table))
  (loop :for k :being :the :hash-keys :of object :using (hash-value v)
        :repeat 64
        :collect (cons (printed k) v)))

(defmethod parts ((object symbol))
  (append (and (boundp object) (list (cons "value" (symbol-value object))))
          (and (fboundp object) (list (cons "function" (fdefinition object))))
          (list (cons "package" (symbol-package object)))
          (and (symbol-plist object) (list (cons "plist" (symbol-plist object))))))

(defun slot-parts (object)
  (loop :for slot :in (sb-mop:class-slots (class-of object))
        :for name := (sb-mop:slot-definition-name slot)
        :collect (cons (string-downcase name)
                       (if (slot-boundp object name) (slot-value object name) '|unbound|))))

(defmethod parts ((object standard-object)) (slot-parts object))
(defmethod parts ((object structure-object)) (slot-parts object))

(defmethod parts ((object condition))
  (list (cons "report" (princ-to-string object))
        (cons "type" (type-of object))))

(defun frame-text (frame)
  (multiple-value-bind (name args) (sb-debug::frame-call frame)
    (printed (cons name args))))

(defmethod parts ((frame sb-di:frame))
  (let ((location (sb-di:frame-code-location frame)))
    (multiple-value-bind (name args) (sb-debug::frame-call frame)
      (append (list (cons "function" name))
              (loop :for arg :in args :for i :from 0 :collect (cons (format nil "arg ~d" i) arg))
              (ignore-errors
               (loop :for var :in (coerce (sb-di::debug-fun-debug-vars (sb-di:frame-debug-fun frame)) 'list)
                     :when (eq (sb-di:debug-var-validity var location) :valid)
                       :collect (cons (string-downcase (sb-di:debug-var-symbol var))
                                      (sb-di:debug-var-value var frame))))))))

(defun backtrace-frames ()
  (let ((frames nil))
    (sb-debug:map-backtrace (lambda (frame) (push frame frames)) :count 60)
    (let* ((frames (nreverse frames))
           (names (mapcar #'sb-debug::frame-call frames))
           (from (let ((at (position-if (lambda (name) (member name '(error cerror sb-kernel::internal-error)))
                                        names :from-end t)))
                   (if at (1+ at) 0)))
           (to (or (position 'eval names :start from) (length frames))))
      (subseq frames from (min to (+ from 8))))))

(defun inspect-window (object)
  (let* ((window (kit:make-window :title (format nil "Inspector — ~(~a~)" (type-of object))
                                  :x 520 :y 140 :width 600 :height 420))
         (view (make-instance 'transcript-view :file "/tmp/Inspector.txt" :choose #'inspect-window
                                               :frame (vector 0 0 576 368))))
    (add-line view (printed object) object)
    (add-line view (format nil "a ~(~a~)" (type-of object)))
    (loop :for (label . value) :in (parts object)
          :do (add-line view (format nil "  ~a: ~a" label (printed value)) value))
    (kit:add-subview (kit:content-view window) view)
    (setf (kit:first-responder window) view)
    (kit:show window)
    window))

(defclass listener-view (transcript-view)
  ((lock :initform (sb-thread:make-mutex :name "listener") :reader listener-lock)
   (chosen :initform (sb-thread:make-waitqueue) :reader chosen)
   (restart :initform nil :accessor chosen-restart)
   (running :initform nil :accessor running)))

(defun seconds-since (start)
  (/ (- (get-internal-real-time) start) internal-time-units-per-second))

(defmethod prompt ((view listener-view))
  (let ((run (first (running view))))
    (if run
        (format nil "  running ~ds — ctrl-c stops   * ~a" (floor (seconds-since (cdr run))) (input view))
        (call-next-method))))

(defun stop-evaluation (view)
  (dolist (run (running view))
    (when (car run)
      (ignore-errors (sb-thread:interrupt-thread (car run) (lambda () (ignore-errors (throw 'stop-evaluation :stopped))))))))

(defun tick-while-running (view)
  (loop :while (running view)
        :do (sleep 1)
            (kit:perform-on-main (lambda () (kit:needs-display view)))))

(defstruct (choice (:constructor make-choice (restart))) restart)

(defun choose-restart (view restart)
  (sb-thread:with-mutex ((listener-lock view))
    (setf (chosen-restart view) restart)
    (sb-thread:condition-broadcast (chosen view))))

(defun await-restart (view)
  (sb-thread:with-mutex ((listener-lock view))
    (loop :until (chosen-restart view)
          :do (sb-thread:condition-wait (chosen view) (listener-lock view)))
    (shiftf (chosen-restart view) nil)))

(defun listener-eval (view text)
  (let ((start (get-internal-real-time)))
    (flet ((show (string &optional object)
             (kit:perform-on-main (lambda () (add-line view string object)))))
      (let ((stopped (eq (catch 'stop-evaluation (eval-and-show view text #'show)) :stopped))
            (seconds (seconds-since start)))
        (cond (stopped (show (format nil "stopped after ~,1fs" seconds)))
              ((> seconds 1/2) (show (format nil "; ~,1fs" seconds))))))))

(defun eval-and-show (view text show)
  (flet ((show (string &optional object) (funcall show string object)))
    (let ((output (make-string-output-stream)))
      (with-simple-restart (abort "Return to the listener")
        (let ((values (handler-bind
                          ((error (lambda (e)
                                    (show (format nil "error: ~a" e) e)
                                    (dolist (frame (backtrace-frames))
                                      (show (format nil "  frame: ~a" (frame-text frame)) frame))
                                    (dolist (r (compute-restarts e))
                                      (show (format nil "  restart: ~a" r) (make-choice r)))
                                    (invoke-restart-interactively (await-restart view)))))
                        (let ((*standard-output* output) (sb-ext:*ed-functions* (list #'ed-in-window)))
                          (multiple-value-list (eval (read-from-string text)))))))
          (dolist (line (uiop:split-string (get-output-stream-string output) :separator '(#\Newline)))
            (unless (string= line "") (show line)))
          (dolist (v values) (show (printed v) v)))))))

(defmethod kit:key-down ((view listener-view) characters keycode)
  (declare (ignore keycode))
  (let ((char (char characters 0)))
    (case char
      (#\Return
       (let ((text (input view)))
         (add-line view (format nil "* ~a" text))
         (setf (input view) "")
         (let ((run (cons nil (get-internal-real-time))))
           (push run (running view))
           (when (null (rest (running view)))
             (bsd:bsdthread-create (lambda () (tick-while-running view)) "listener clock"))
           (setf (car run)
                 (bsd:bsdthread-create (lambda ()
                                         (unwind-protect (listener-eval view text)
                                           (kit:perform-on-main
                                            (lambda ()
                                              (setf (running view) (remove run (running view)))
                                              (kit:needs-display view)))))
                                       "listener eval")))))
      (#\Etx (stop-evaluation view))
      (#\Backspace
       (when (plusp (length (input view)))
         (setf (input view) (subseq (input view) 0 (1- (length (input view)))))))
      (t (setf (input view) (concatenate 'string (input view) characters))))
    (kit:needs-display view))
  t)

(defun listener-choose (view)
  (lambda (object)
    (if (choice-p object)
        (choose-restart view (choice-restart object))
        (inspect-window object))))

(bsd:define-program "Listener" (argv envp)
  (setf kit:*menus* (kit:standard-menus "Listener"))
  (let* ((window (kit:make-window :title "Listener" :x 180 :y 90 :width 720 :height 480))
         (view (make-instance 'listener-view :file "/tmp/Listener.txt" :frame (vector 0 0 696 428))))
    (setf (input view) ""
          (choose view) (listener-choose view))
    (kit:add-subview (kit:content-view window) view)
    (setf (kit:first-responder window) view)
    (kit:show window)
    (kit:run)))
