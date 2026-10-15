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

(defun shown-lines (view)
  (let ((rows (floor (- (kit:view-height view) 8) +line-height+))
        (all (append (lines view) (and (input view) (list (cons (format nil "* ~a" (input view)) nil))))))
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
   (restart :initform nil :accessor chosen-restart)))

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
  (flet ((show (string &optional object)
           (kit:perform-on-main (lambda () (add-line view string object)))))
    (let ((output (make-string-output-stream)))
      (with-simple-restart (abort "Return to the listener")
        (let ((values (handler-bind
                          ((error (lambda (e)
                                    (show (format nil "error: ~a" e) e)
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
         (bsd:bsdthread-create (lambda () (listener-eval view text)) "listener eval")))
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
