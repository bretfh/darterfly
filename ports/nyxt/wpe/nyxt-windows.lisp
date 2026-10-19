;;;; Nyxt's in-world presentation through the existing Layer service.
;;;; There is no Nyxt window server, privileged broker or second window socket.
(defpackage #:darterfly/nyxt-windows
  (:use #:cl)
  (:local-nicknames (#:wire #:darterfly/nyxt-wire) (#:layer #:darterfly/layer))
  (:export #:make-session #:dispatch #:next-event #:close-session))
(in-package #:darterfly/nyxt-windows)
(defstruct native-window context id root (views (make-hash-table)))
(defstruct session
  (windows (make-hash-table)) (frames (make-hash-table)) (frame-bytes 0)
  (lock (sb-thread:make-mutex :name "Nyxt display")) (closed nil)
  (task darterfly/mach:*task*) (proc darterfly/bsd:*proc*))
(defun close-session (session)
  (sb-thread:with-recursive-lock ((session-lock session))
    (unless (session-closed session)
      (setf (session-closed session) t)
      (maphash (lambda (id window) (declare (ignore id))
        (ignore-errors (layer:transaction-commit
          (list (list :order (native-window-id window) :out)))))
        (session-windows session))
      (clrhash (session-windows session))
      (clrhash (session-frames session))
      (setf (session-frame-bytes session) 0))))
(defun dispatch (session op id &key (seq 0) (a 0) (b 0) (data #()))
  (declare (ignore seq))
  (sb-thread:with-recursive-lock ((session-lock session))
    (when (session-closed session) (error "Nyxt display is closed"))
    (let ((windows (session-windows session)) (frames (session-frames session))
          (darterfly/mach:*task* (session-task session))
          (darterfly/bsd:*proc* (session-proc session)))
      (symbol-macrolet ((frame-bytes (session-frame-bytes session)))
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
          (106
           (let ((window (gethash id windows)))
             (when window
               (layer:transaction-commit
                 (list (list :order (native-window-id window) :above))))))
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
          (109 (close-session session))
          (t (error "Unknown window operation ~d" op)))))))
(defun next-event (session)
  ;; Context ports are created in the app's BSD task. The caller preserves
  ;; that task binding, just like the existing Layer world event pump.
  (let ((windows
          (sb-thread:with-mutex ((session-lock session))
            (loop for id being the hash-keys of (session-windows session)
                  using (hash-value window) collect (cons id window)))))
    (dolist (entry windows)
      (let* ((id (car entry)) (window (cdr entry))
             (event (layer:next-event (native-window-context window) :timeout 1)))
        (case (getf event :type)
          (:key-down
           (return-from next-event (values 201 id 0 (getf event :keycode)
             (char-code (or (getf event :character) #\Null))
             (wire:words (or (getf event :modifiers) 0)))))
          ((:left-mouse-down :left-mouse-up)
           (destructuring-bind (x y) (getf event :window-location)
             (when (and (>= x 0) (>= y 0))
               (return-from next-event (values 202 id
                 (if (eq (getf event :type) :left-mouse-down) 1 0)
                 x y #()))))))))
    (values 0 0 0 0 0 #())))
