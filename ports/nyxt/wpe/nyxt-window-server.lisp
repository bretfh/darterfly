;; Window-system adapter. All objects belong to this connection; no reader/eval
;; crosses the world boundary. Disconnect removes every client window.
(defpackage #:darterfly/nyxt-windows
  (:use #:cl)
  (:local-nicknames (#:wire #:darterfly/nyxt-wire)
                   (#:layer #:darterfly/layer) (#:bsd #:darterfly/bsd)))
(in-package #:darterfly/nyxt-windows)
(defvar *trace-packets* nil)
(defstruct native-window context id root (views (make-hash-table)))
(defun serve-client (connection)
  (let ((windows (make-hash-table)) (frames (make-hash-table)) (frame-bytes 0))
    (unwind-protect
      (loop
        (when (plusp (first (bsd::poll-fds
                            (list (list (wire:connection-fd connection) 1)) 10)))
          (multiple-value-bind (op id seq a b data) (wire:receive-packet connection)
            (declare (ignore seq))
            (when *trace-packets*
              (format t "~&[NYXT WINDOW OP ~d ID ~d BYTES ~d]~%" op id (length data))
              (finish-output))
            (case op
              (102
               (assert (and (< (hash-table-count windows) 16)
                            (<= 64 a 2048) (<= 64 b 2048) (not (gethash id windows))))
               (let* ((context (layer:context-create))
                      (root (layer:make-layer :masks-to-bounds t :background-color #(.13 .16 .2 1.0))))
                 (setf (layer:layer-frame root) (vector 0 0 a b)
                       (layer:context-layer context) root)
                 (layer:commit context)
                 (setf (gethash id windows)
                   (make-native-window :context context :root root
                     :id (layer:window-create context 80 80 a b)))))
              (103
               (let* ((window (or (gethash id windows) (error "Unknown window")))
                      (view (or (gethash a (native-window-views window))
                                (setf (gethash a (native-window-views window))
                                  (layer:make-layer)))))
                 (assert (= (length data) 8))
                 (let ((width (wire:u32 data 0)) (height (wire:u32 data 4)))
                   (assert (and (<= width 2048) (<= height 2048) (<= b 2048))))
                 (setf (layer:layer-frame view)
                       (vector 0 b (wire:u32 data 0) (wire:u32 data 4)))
                 (setf (layer:layer-contents view) (gethash a frames))
                 (pushnew view (layer:layer-sublayers (native-window-root window)))
                 (layer:commit (native-window-context window))))
              (104
               (assert (and (<= 1 a 2048) (<= 1 b 2048) (= (length data) (* a b 4))))
               (let* ((old (gethash id frames))
                      (total (+ frame-bytes (length data)
                                (- (if old (length (getf old :pixels)) 0)))))
                 (assert (and (or old (< (hash-table-count frames) 64))
                              (<= total (* 128 1024 1024))))
                 (setf frame-bytes total))
               (let ((pixels (copy-seq data)))
                 (declare (type (simple-array (unsigned-byte 8) (*)) pixels)
                          (optimize (speed 3)))
                 ;; WPE SHM is premultiplied BGRA; Layer images are RGBA bytes.
                 (loop for i below (length pixels) by 4
                       do (rotatef (aref pixels i) (aref pixels (+ i 2))))
                 (setf (gethash id frames) (layer:image a b pixels))
                 (maphash (lambda (key window)
                   (declare (ignore key))
                   (let ((view (gethash id (native-window-views window))))
                     (when view
                       (setf (layer:layer-contents view) (gethash id frames))
                       (layer:commit (native-window-context window))))) windows)))
              (105
               (let ((window (gethash id windows)))
                 (when window
                   (layer:transaction-commit
                     (list (list :order (native-window-id window) :out)))
                   (remhash id windows))))
              (107 ; Detach a buffer, retaining its last frame for switching back.
               (let* ((window (gethash id windows))
                      (view (and window (gethash a (native-window-views window)))))
                 (when view
                   (setf (layer:layer-sublayers (native-window-root window))
                     (remove view (layer:layer-sublayers (native-window-root window))))
                   (remhash a (native-window-views window))
                   (layer:commit (native-window-context window)))))
              (108 ; Release the frame and every attachment of a deleted buffer.
               (let ((old (gethash id frames)))
                 (when old (decf frame-bytes (length (getf old :pixels))))
                 (remhash id frames))
               (maphash (lambda (key window)
                 (declare (ignore key))
                 (let ((view (gethash id (native-window-views window))))
                   (when view
                     (setf (layer:layer-sublayers (native-window-root window))
                       (remove view (layer:layer-sublayers (native-window-root window))))
                     (remhash id (native-window-views window))
                     (layer:commit (native-window-context window))))) windows))
              (109 (return))
              (t (error "Unknown window operation ~d" op)))))
        (maphash
          (lambda (id window)
            (loop for event = (layer:next-event (native-window-context window) :timeout 1)
                  while event do
              (case (getf event :type)
                (:key-down
                 (wire:send-packet connection 201 id
                   :a (getf event :keycode) :b (char-code (or (getf event :character) #\Null))
                   :data (wire:words (or (getf event :modifiers) 0))))
                ((:left-mouse-down :left-mouse-up)
                 (destructuring-bind (x y) (getf event :window-location)
                   (when (and (>= x 0) (>= y 0))
                     (wire:send-packet connection 202 id :a x :b y
                       :seq (if (eq (getf event :type) :left-mouse-down) 1 0)))))))) windows))
      (maphash (lambda (id window) (declare (ignore id))
        (ignore-errors (layer:transaction-commit
          (list (list :order (native-window-id window) :out))))) windows)
      (wire:close-connection connection))))
(bsd:define-program "Nyxt Windows" (argv envp)
  (let ((fd (bsd:socket 1 1)))
    (unwind-protect
      (progn
        (bsd:bind fd "/tmp/nyxt-windows.sock") (bsd:listen fd 1)
        (format t "~&[NYXT WINDOW SERVICE READY]~%") (finish-output)
        (handler-case (serve-client (wire:make-connection :fd (bsd:accept fd) :root t))
          (error (e) (format t "~&[NYXT WINDOW SERVICE ERROR] ~a~%" e)))
        (format t "~&[NYXT WINDOW SERVICE EXIT]~%"))
      (bsd:close fd)
      (ignore-errors (bsd:unlink "/tmp/nyxt-windows.sock")))))
