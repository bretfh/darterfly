;;;; WPE renderer extension: no changes to Nyxt's core or command system.
(nyxt:define-package #:nyxt/renderer/wpe)
(in-package #:nyxt/renderer/wpe)
(define-class wpe-renderer (renderer) ((name "WPE / Darterfly"))
  (:metaclass user-class))
(define-class wpe-browser () () (:metaclass user-class))
(define-class wpe-buffer ()
  ((native-lock (bt:make-lock "WPE buffer lifetime") :type t)
   (native-callback-lock (sb-thread:make-mutex :name "WPE callback lifetime") :type t)
   (native-id nil :type (or null unsigned-byte)) (native-url "about:blank") (native-title "")
   (native-width 640) (native-height 400) (native-zoom 1.0)
   (native-ready nil) (native-navigation nil) (native-frame-count 0)) (:metaclass user-class))
(define-class wpe-window ()
  ((native-id nil :type (or null unsigned-byte)) (native-width 640) (native-height 480)
   (native-layout '() :type list) (native-focus nil :type t)) (:metaclass user-class))
(define-class wpe-scheme () () (:metaclass user-class))
(defvar *engine* nil)
(defvar *windows* nil)
(defvar *engine-process* nil)
(defvar *socket-path* nil)
(defvar *next-id* 0)
(defvar *serial* 0)
(defvar *buffers* (make-hash-table :synchronized t))
(defvar *native-windows* (make-hash-table :synchronized t))
(defvar *registry-lock* (bt:make-lock "Nyxt IDs"))
(defun next-id () (bt:with-lock-held (*registry-lock*) (incf *next-id*)))
(defvar *replies* (make-hash-table))
(defvar *reply-lock* (bt:make-lock "WPE replies"))
(defvar *failure* nil)
(defvar *closing* nil)
(defvar *uninstalled* nil)
(defvar *event-count* 0)
(defvar *engine-thread* nil)
(defvar *input-thread* nil)
(defvar *dispatch-threads* nil)
(defvar *event-queue* nil)
(defvar *scheme-queue* nil)
(defvar *frame-queue* nil)
(defvar *shutdown-complete* nil)
(defvar *shutdown-lock* (sb-thread:make-mutex :name "Nyxt shutdown"))
(defun window-call (op id &rest keys)
  (apply #'darterfly/nyxt-windows:dispatch *windows* op id keys))
(defun app-thread (function name)
  (let ((task darterfly/mach:*task*) (proc darterfly/bsd:*proc*))
    (bt:make-thread (lambda ()
      (let ((darterfly/mach:*task* task) (darterfly/bsd:*proc* proc))
        (funcall function))) :name name)))
(defun engine-send (op id &rest keys)
  (handler-case
      (apply #'darterfly/nyxt-wire:send-packet *engine* op id keys)
    (error (e) (unless *closing* (setf *failure* e)) (error e))))
(defun buffer-command (buffer op &rest keys)
  ;; Prompt producers can finish after the prompt was dismissed. Serialize
  ;; submission with deletion; an obsolete UI update has no remaining target.
  (bt:with-lock-held ((native-lock buffer))
    (when (and (native-id buffer) (not *closing*))
      (apply #'engine-send op (native-id buffer) keys))))
(defun rpc (op id &rest keys)
  (let ((seq (bt:with-lock-held (*reply-lock*)
               (when (>= (hash-table-count *replies*) 128)
                 (error "Too many pending WPE requests"))
               (setf (gethash (incf *serial*) *replies*) :pending) *serial*)))
    (unwind-protect
        (progn
          (apply #'engine-send op id :seq seq keys)
          (loop repeat 3000 do
            (when (or *failure* *closing*)
              (error "WPE stopped: ~a" *failure*))
            (let ((answer (bt:with-lock-held (*reply-lock*)
                            (gethash seq *replies*))))
              (when (consp answer)
                (unless (= (car answer) 1000) (error "WPE: ~a" (cdr answer)))
                (return-from rpc (cdr answer))))
            (sleep .01))
          (setf *failure* (format nil "WPE operation ~d timed out" op))
          (error "~a" *failure*))
      (bt:with-lock-held (*reply-lock*) (remhash seq *replies*)))))
(defun dispatch-worker (queue)
  (loop for thunk = (darterfly/nyxt-work:take queue) while thunk do
    (unless *closing*
      (handler-case (funcall thunk)
        (error (e) (unless *closing*
                     (format t "~&[NYXT WPE CALLBACK ERROR] ~a~%" e)
                     (sb-debug:print-backtrace :count 20)
                     (finish-output) (setf *failure* e)))))))
(defun start-dispatch ()
  (setf *event-queue* (darterfly/nyxt-work:make-queue)
        *scheme-queue* (darterfly/nyxt-work:make-queue :limit 64)
        *frame-queue* (darterfly/nyxt-work:make-queue
                       :limit 64 :byte-limit (* 64 1024 1024) :coalesce t)
        *dispatch-threads*
        (loop for (queue name) in
          (list (list *event-queue* "Nyxt ordered events")
                (list *scheme-queue* "Nyxt schemes 1")
                (list *scheme-queue* "Nyxt schemes 2")
                (list *frame-queue* "Nyxt presentation"))
          collect (let ((q queue)) (app-thread (lambda () (dispatch-worker q)) name)))))
(defun callback-thread (id buffer thunk bytes)
  ;; One FIFO worker preserves event order. It may make synchronous engine
  ;; calls: the reply reader and scheme workers never wait on this queue.
  (darterfly/nyxt-work:enqueue *event-queue* id
    (lambda ()
      ;; A callback may synchronously call the engine or delete its own buffer.
      ;; Serialize it with deletion without holding the transport/view lock.
      (sb-thread:with-recursive-lock ((native-callback-lock buffer))
        (when (and (not *closing*) (eql id (native-id buffer)))
          (funcall thunk)))) bytes))
(defun queue-frame (id buffer width height pixels)
  (unless (and (<= 1 width 2048) (<= 1 height 2048)
               (= (length pixels) (* width height 4)))
    (error "Invalid WPE frame"))
  (darterfly/nyxt-work:enqueue *frame-queue* id
    (lambda ()
      ;; A queued frame must not recreate a deleted view's cached pixels.
      (bt:with-lock-held ((native-lock buffer))
        (when (and (not *closing*) (eql id (native-id buffer)))
          (window-call 104 id :a width :b height :data pixels)
          (incf (native-frame-count buffer))))) (length pixels)))
(defun scheme-request (id seq uri)
  (handler-case
    (let* ((*read-eval* nil) (parsed (quri:uri uri))
           (callbacks (gethash (quri:uri-scheme parsed) nyxt::*schemes*)))
      (unless callbacks (error "Unknown internal scheme"))
      (let ((source (gethash id *buffers*)))
        (unless source (error "Unknown requesting view"))
        (when (and (equal (quri:uri-scheme parsed) "lisp")
                   (web-buffer-p source)
                   (not (equal "nyxt" (quri:uri-scheme (quri:uri (native-url source))))))
          (error "Web content cannot invoke Nyxt's internal Lisp callbacks")))
      (multiple-value-bind (body mime status) (funcall (first callbacks) uri)
        (let ((body (if (equal body "") "<html><head></head><body></body></html>" body)))
          (engine-send 10 id :seq seq :a (or status 200)
            :data (concatenate '(vector (unsigned-byte 8))
                    (darterfly/nyxt-wire:utf8 (format nil "~a~%" (or mime "text/html")))
                    (if (stringp body) (darterfly/nyxt-wire:utf8 body) body))))))
    (error (e)
      (format t "~&[NYXT SCHEME REQUEST REJECTED] ~a: ~a~%" uri e)
      (engine-send 10 id :seq seq :a 500
                   :data (format nil "text/plain~%~a" e)))))
(defun engine-loop ()
  (handler-case
    (loop
      (multiple-value-bind (op id seq a b data) (darterfly/nyxt-wire:receive-packet *engine*)
        (let ((buffer (gethash id *buffers*)))
          (case op
            ((1000 1001)
             (if (plusp seq)
                 (bt:with-lock-held (*reply-lock*)
                   (when (gethash seq *replies*)
                     (setf (gethash seq *replies*)
                           (cons op (darterfly/nyxt-wire:text data)))))
                 (when (and (= op 1001) buffer (native-id buffer) (not *closing*))
                   (format t "~&[NYXT ASYNC JAVASCRIPT ERROR] ~a~%"
                           (darterfly/nyxt-wire:text data)))))
            (1100
             (when (and buffer (native-id buffer) (not *closing*))
               (queue-frame id buffer a b data)))
            (1101
             (when buffer
               (let ((uri (quri:uri (darterfly/nyxt-wire:text data))))
                 (when (= a 3) (setf (native-ready buffer) t))
                 (when (and (web-buffer-p buffer) (native-navigation buffer))
                   (callback-thread id buffer
                     (lambda ()
                       (setf (url buffer) uri)
                       (case a
                         (0 (setf (nyxt::status buffer) :loading)
                            (on-signal-load-started buffer uri))
                         (1 (on-signal-load-redirected buffer uri))
                         (2 (on-signal-load-committed buffer uri))
                         (3 (setf (nyxt::status buffer) :finished)
                            (on-signal-load-finished buffer uri
                              (native-title buffer))))) (length data))))))
            (1102 (when buffer
                    (let ((title (darterfly/nyxt-wire:text data)))
                      (setf (native-title buffer) title)
                      (when (web-buffer-p buffer)
                        (callback-thread id buffer
                          (lambda () (on-signal-notify-title buffer title)) (length data))))))
            (1103
             (when buffer
               (let ((uri (darterfly/nyxt-wire:text data)))
                 (setf (native-url buffer) uri)
                 (when (web-buffer-p buffer)
                   (callback-thread id buffer
                     (lambda () (on-signal-notify-uri buffer (quri:uri uri)))
                     (length data))))))
            (1104 (let ((uri (darterfly/nyxt-wire:text data)))
                    (darterfly/nyxt-work:enqueue *scheme-queue* id
                      (lambda () (scheme-request id seq uri)) (length data))))
            (1106 (unless *closing*
                    (setf *failure* (darterfly/nyxt-wire:text data))))
            (1105 (format t "~&[NYXT PAGE ERROR] ~a~%" (darterfly/nyxt-wire:text data))
                  (when (and buffer (web-buffer-p buffer))
                    (callback-thread id buffer
                      (lambda () (setf (nyxt::status buffer) :failed)) (length data))))))))
    (error (e) (unless *closing* (setf *failure* e)
                 (format t "~&[NYXT ENGINE CONNECTION ERROR] ~a~%" e)))))
(declaim (ftype function input-loop))
(defun start-engine ()
  (setf *closing* nil *failure* nil *shutdown-complete* nil)
  (setf *windows* (darterfly/nyxt-windows:make-session))
  (setf *socket-path* (format nil "/tmp/nyxt-engine-~d.sock"
                               (sb-thread:thread-os-tid sb-thread:*current-thread*)))
  (with-open-file (log "/tmp/nyxt-engine.log" :direction :output
                       :if-exists nil :if-does-not-exist :create)
    (when log (finish-output log)))
  (setf *engine-process*
    (uiop:launch-program (list "/usr/bin/nyxt-wpe-engine" *socket-path*)
      :output "/tmp/nyxt-engine.log" :error-output :output
      :if-output-exists :append))
  (setf *engine* (darterfly/nyxt-wire:connect-local *socket-path*))
  (start-dispatch)
  (setf *engine-thread* (app-thread #'engine-loop "WPE events")
        *input-thread* (app-thread #'input-loop "Darterfly window input"))
  (maphash (lambda (name callbacks) (declare (ignore callbacks))
            (rpc 11 0 :data name)) nyxt::*schemes*))
(defmethod install ((renderer wpe-renderer))
  (setf *uninstalled* nil)
  (dolist (pair '((renderer-browser wpe-browser) (renderer-buffer wpe-buffer)
                 (renderer-window wpe-window) (renderer-scheme wpe-scheme)))
    (closer-mop:ensure-finalized
      (closer-mop:ensure-class (first pair) :direct-superclasses (rest pair)
        :metaclass 'interface-class))))
(defmethod uninstall ((renderer wpe-renderer))
  ;; Upstream quit invokes this after closing the engine and all windows.
  ;; Release precisely the interface classes installed by this extension.
  (dolist (name '(renderer-browser renderer-buffer renderer-window renderer-scheme))
    (closer-mop:ensure-finalized
      (closer-mop:ensure-class name :direct-superclasses '()
        :metaclass 'interface-class)))
  (setf *uninstalled* t))
(defmethod ffi-initialize ((browser wpe-browser) urls startup-timestamp)
  (start-engine) (call-next-method))
(defun engine-exited-p (seconds)
  (loop with until = (+ (get-internal-real-time)
                        (* seconds internal-time-units-per-second))
        unless (and *engine-process* (uiop:process-alive-p *engine-process*))
          return t
        when (>= (get-internal-real-time) until) return nil
        do (sleep .05)))
(defun shutdown-engine ()
  ;; Also callable after partial startup. Init's health check is the outer
  ;; bound if this world cannot complete cleanup itself.
  (sb-thread:with-mutex (*shutdown-lock* :timeout 1)
    (unless *shutdown-complete*
      (setf *closing* t)
      (dolist (queue (list *event-queue* *scheme-queue* *frame-queue*))
        (when queue (darterfly/nyxt-work:close-queue queue)))
      (when *engine*
        (let ((darterfly/nyxt-wire:*io-timeout* 1))
          (ignore-errors (engine-send 9 0))))
      (unless (engine-exited-p 2)
        (format t "~&[NYXT ENGINE FORCED STOP]~%")
        (ignore-errors (uiop:terminate-process *engine-process* :urgent t)))
      (when (and *engine-process* (engine-exited-p 2))
        ;; WAIT-PROCESS is safe only after the nonblocking status says dead.
        (format t "~&[NYXT ENGINE WAIT ~s]~%" (uiop:wait-process *engine-process*)))
      (when *engine* (darterfly/nyxt-wire:cancel-connection *engine*))
      (when *windows* (ignore-errors (window-call 109 0)))
      (dolist (thread (append (list *engine-thread* *input-thread*) *dispatch-threads*))
        (when (and thread (not (eq thread (bt:current-thread))))
          (sb-thread:join-thread thread :timeout 2 :default nil)))
      ;; All remaining callbacks belong to this app world. Its exit reclaims
      ;; their descriptors and every native descendant via end-world-proc.
      (when *socket-path* (ignore-errors (uiop:delete-file-if-exists *socket-path*)))
      (setf *shutdown-complete* t)
      (finish-output))))
(defun drain-file-writers ()
  ;; Upstream QUIT clears *BROWSER* immediately after FFI-KILL-BROWSER.
  ;; NFiles history serialization still reads it from asynchronous workers.
  ;; Join those existing workers while the browser remains valid; never
  ;; replace the persistence implementation or pretend a stalled write passed.
  (loop with until = (+ (get-internal-real-time)
                        (* 5 internal-time-units-per-second))
        for workers = (sera:synchronized (files::*cache*)
                        (loop for entry being the hash-values of files::*cache*
                              for worker = (sera:synchronized (entry)
                                             (files::worker entry))
                              when worker collect worker))
        unless (some #'bt:thread-alive-p workers) return t
        when (>= (get-internal-real-time) until)
          do (error "Nyxt file writers did not finish before shutdown")
        do (sleep .01)))
(defmethod ffi-kill-browser ((browser wpe-browser))
  (handler-case
      (progn (shutdown-engine) (drain-file-writers))
    (error (e) (setf *failure* e) (error e))))
(defmethod initialize-instance :after ((buffer wpe-buffer) &key &allow-other-keys)
  (ffi-buffer-initialize-foreign-object buffer))
(defmethod ffi-buffer-initialize-foreign-object ((buffer wpe-buffer))
  (unless (native-id buffer)
    (setf (native-id buffer) (next-id)
          (gethash (native-id buffer) *buffers*) buffer)
    (rpc 1 (native-id buffer) :a (native-width buffer) :b (native-height buffer)
      :data (vector (if (web-buffer-p buffer) 0 1)))
    (engine-send 3 (native-id buffer)
      :data "<!doctype html><html><head></head><body></body></html>")
    (loop repeat 2000 until (native-ready buffer) do
      (when *failure* (error "WPE initialization: ~a" *failure*))
      (sleep .01)
      finally (unless (native-ready buffer) (error "WPE blank view did not load"))))
  buffer)
(defmethod ffi-buffer-url ((buffer wpe-buffer)) (quri:uri (native-url buffer)))
(defmethod ffi-buffer-title ((buffer wpe-buffer)) (native-title buffer))
(defmethod ffi-buffer-load ((buffer wpe-buffer) url)
  (setf (native-ready buffer) nil (native-navigation buffer) t)
  (buffer-command buffer 2 :data (quri:render-uri url)) buffer)
(defmethod ffi-buffer-reload ((buffer wpe-buffer))
  (buffer-command buffer 12) buffer)
(defmethod ffi-buffer-load-alternate-html ((buffer wpe-buffer) html content-url url)
  (declare (ignore content-url url)) (buffer-command buffer 3 :data html))
(defmethod ffi-buffer-evaluate-javascript ((buffer wpe-buffer) javascript &optional world-name)
  (when world-name (error "Named JavaScript worlds are not yet supported by WPE transport"))
  (bt:with-lock-held ((native-lock buffer))
    (when (and (native-id buffer) (not *closing*))
      (j:decode (rpc 4 (native-id buffer) :data javascript)))))
(defmethod ffi-buffer-evaluate-javascript-async ((buffer wpe-buffer) javascript &optional world-name)
  (when world-name (error "Named JavaScript worlds are not yet supported"))
  ;; Preserve command order. Spawning one thread per async evaluation can put
  ;; a status update before the HTML skeleton it was meant to update.
  (buffer-command buffer 4 :data javascript) nil)
(defun selected-text (buffer)
  (ffi-buffer-evaluate-javascript buffer
    "(()=>{let e=document.activeElement;return e && typeof e.selectionStart==='number' ? e.value.substring(e.selectionStart,e.selectionEnd) : window.getSelection().toString()})()"))
(defmethod ffi-buffer-copy ((buffer wpe-buffer) &optional (text nil supplied))
  (copy-to-clipboard (if supplied text (selected-text buffer))))
(defmethod ffi-buffer-cut ((buffer wpe-buffer))
  (let ((text (ffi-buffer-copy buffer)))
    (rpc 22 (native-id buffer)) text))
(defmethod ffi-buffer-paste ((buffer wpe-buffer) &optional (text nil supplied))
  (let ((text (if supplied text (trivial-clipboard:text))))
    (rpc 21 (native-id buffer) :data text) text))
(defmethod ffi-buffer-zoom-ratio ((buffer wpe-buffer)) (native-zoom buffer))
(defmethod (setf ffi-buffer-zoom-ratio) (value (buffer wpe-buffer))
  (assert (and (realp value) (<= .1 value 10)))
  (buffer-command buffer 15 :a (round (* value 1000)))
  (setf (native-zoom buffer) value))
(defmethod ffi-buffer-navigate-backwards ((buffer wpe-buffer))
  (buffer-command buffer 13))
(defmethod ffi-buffer-navigate-forwards ((buffer wpe-buffer))
  (buffer-command buffer 14))
(defmethod ffi-buffer-delete :around ((buffer wpe-buffer))
  ;; Include upstream hooks and registry removal, not just native destruction.
  (sb-thread:with-recursive-lock ((native-callback-lock buffer))
    (call-next-method)))
(defmethod ffi-buffer-delete ((buffer wpe-buffer))
  (bt:with-lock-held ((native-lock buffer))
    (when (native-id buffer)
      (let ((id (native-id buffer)))
        (maphash (lambda (key window)
          (declare (ignore key))
          (setf (native-layout window)
                (remove buffer (native-layout window) :key #'first))) *native-windows*)
        (darterfly/nyxt-work:discard *frame-queue* id)
        (darterfly/nyxt-work:discard *event-queue* id)
        (darterfly/nyxt-work:discard *scheme-queue* id)
        (window-call 108 id)
        (engine-send 8 id) (remhash id *buffers*)
        (setf (native-id buffer) nil)))))
(defmethod ffi-width ((buffer wpe-buffer)) (native-width buffer))
(defmethod ffi-height ((buffer wpe-buffer)) (native-height buffer))
(defmethod ffi-width ((window wpe-window)) (native-width window))
(defmethod ffi-height ((window wpe-window)) (native-height window))
(defun place (window buffer y height)
  (when buffer
    (setf (native-width buffer) (native-width window) (native-height buffer) height)
    (when (plusp height)
      (engine-send 5 (native-id buffer) :a (native-width window) :b height))
    (window-call 103 (native-id window) :a (native-id buffer) :b y
      :data (darterfly/nyxt-wire:words (native-width window) height))
    (push (list buffer y height) (native-layout window))))
(defun layout (window)
  (let* ((prompt (first (nyxt::active-prompt-buffers window)))
         (ph (if prompt (native-height prompt) 0))
         (status (status-buffer window)) (message (message-buffer window))
         (sh (min 80 (native-height status))) (mh (min 40 (native-height message)))
         (height (max 1 (- (native-height window) ph sh mh))))
    (dolist (item (native-layout window))
      (window-call 107 (native-id window) :a (native-id (first item))))
    (setf (native-layout window) nil)
    (place window (active-buffer window) 0 height)
    (place window status height sh)
    (place window message (+ height sh) mh)
    (when prompt (place window prompt (+ height sh mh) ph))))
(defmethod initialize-instance :after ((window wpe-window) &key &allow-other-keys)
  (setf (native-id window) (next-id)
        (gethash (native-id window) *native-windows*) window
        (native-height (status-buffer window)) 32
        (native-height (message-buffer window)) 24)
  (window-call 102 (native-id window)
    :a (native-width window) :b (native-height window))
  (layout window))
(defmethod ffi-window-set-buffer ((window wpe-window) (buffer wpe-buffer) &key focus)
  (declare (ignore focus))
  (setf (slot-value window 'nyxt::active-buffer) buffer (native-focus window) buffer)
  (layout window)
  (nyxt::print-status (status-buffer window))
  buffer)
(defmethod ffi-window-delete ((window wpe-window))
  (window-call 105 (native-id window))
  (remhash (native-id window) *native-windows*))
(defmethod ffi-window-title ((window wpe-window)) (nyxt::titler window))
(defmethod (setf ffi-window-title) (title (window wpe-window))
  (when (native-id window)
    (window-call 110 (native-id window) :title title))
  title)
(defmethod (setf ffi-height) (value (buffer wpe-buffer))
  (setf (native-height buffer) (max 0 (min 400 value)))
  (when (window buffer) (layout (window buffer))) value)
(defmethod ffi-focus-buffer ((buffer wpe-buffer))
  (let ((window (or (window buffer) (current-window))))
    (when window (setf (native-focus window) buffer))) buffer)
(defmethod ffi-focused-p ((buffer wpe-buffer))
  (eq buffer (native-focus (current-window))))
(defun key-name (code char mods)
  (or (cdr (assoc code '((1 . "escape") (14 . "backspace") (15 . "tab")
        (28 . "return") (103 . "up") (108 . "down") (105 . "left")
        (106 . "right") (102 . "home") (107 . "end")
        (104 . "pageup") (109 . "pagedown") (111 . "delete"))))
      (when (plusp char)
        (string (code-char (if (and (logbitp 0 mods) (<= 1 char 26)) (+ char 96) char))))))
(defun input-loop ()
  (handler-case
    (loop until *closing* do
      (multiple-value-bind (op id seq a b data) (darterfly/nyxt-windows:next-event *windows*)
        (when (zerop op) (sleep .005))
        (let* ((window (gethash id *native-windows*))
               (buffer (and window (or (native-focus window) (active-buffer window)))))
          (when buffer
            (incf *event-count*)
            (case op
              (203
               (when (and (<= 64 a 2048) (<= 64 b 2048)
                          (or (/= a (native-width window)) (/= b (native-height window))))
                 (setf (native-width window) a (native-height window) b)
                 (window-call 111 id :a a :b b)
                 (layout window)))
              (201
               (let* ((mods (if (= (length data) 4) (darterfly/nyxt-wire:u32 data 0) 0))
                      (name (key-name a b mods))
                      (key (and name (keymaps:make-key :value name
                        :modifiers (loop for (bit label) in '((0 "control") (1 "shift") (2 "meta") (3 "super"))
                                         when (logbitp bit mods) collect label)
                        :status :pressed))))
                 (when key
                   (setf (key-stack buffer) (append (key-stack buffer) (list key)))
                   (on-signal-key-press buffer key))
                 (unless (and key (dispatch-input-event (list op a b) buffer))
                   (cond
                     ((and (logbitp 0 mods) (= a 46)) (ffi-buffer-copy buffer))
                     ((and (logbitp 0 mods) (= a 45)) (ffi-buffer-cut buffer))
                     ((and (logbitp 0 mods) (= a 47)) (ffi-buffer-paste buffer))
                     (t
                   (let ((symbol (or (cdr (assoc a '((1 . #xff1b) (14 . #xff08)
                         (15 . #xff09) (28 . #xff0d) (103 . #xff52) (108 . #xff54)
                         (105 . #xff51) (106 . #xff53) (111 . #xffff))))
                         (if (and (logbitp 0 mods) (<= 1 b 26)) (+ b 96) b))))
                     (engine-send 6 (native-id buffer) :a a :b symbol :data (darterfly/nyxt-wire:words mods))))))))
              (204
               (let ((hit (find-if (lambda (item)
                                    (<= (second item) b
                                        (1- (+ (second item) (third item)))))
                                  (native-layout window))))
                 (when hit
                   (engine-send 20 (native-id (first hit)) :a a
                     :b (- b (second hit)) :data data))))
              (202
               (let ((hit (find-if (lambda (item) (<= (second item) b
                                           (1- (+ (second item) (third item)))))
                                  (native-layout window))))
                 (when hit
                   (setf buffer (first hit) (native-focus window) buffer)
                   (engine-send 7 (native-id buffer) :a a :b (- b (second hit))
                     :data (darterfly/nyxt-wire:words seq))))))))))
    (error (e) (unless *closing* (setf *failure* e)
                 (format t "~&[NYXT INPUT ERROR] ~a~%" e)))))
;; Adapt the clipboard dependency at the platform boundary; Nyxt stays upstream.
(setf (symbol-function 'trivial-clipboard:text)
      (lambda (&optional text)
        (if text (setf (darterfly/layer:clipboard-text) text)
            (darterfly/layer:clipboard-text))))

(setf nyxt::*renderer* (make-instance 'wpe-renderer))

(defun worker-failed (condition previous-hook)
  (declare (ignore previous-hook))
  ;; Upstream startup and command workers use Bordeaux Threads. Report an
  ;; unhandled worker failure to the app loop, then unwind only that worker;
  ;; SBCL's noninteractive debugger otherwise tries to exit the whole runtime
  ;; from inside an arbitrary startup thread.
  (setf *failure* condition)
  (format t "~&[NYXT WORKER FAILED] ~a~%" condition)
  (finish-output)
  (sb-thread:abort-thread))

(export 'launch)
(defun launch (urls &key (online-suggestions t suggestions-supplied-p))
  "Start upstream Nyxt's normal browser initialization with native WPE views."
  (when *engine* (error "The WPE renderer is already running"))
  (setf bt:*default-special-bindings*
    (acons 'sb-ext:*invoke-debugger-hook* '(function worker-failed)
      (remove 'sb-ext:*invoke-debugger-hook* bt:*default-special-bindings*
              :key #'car)))
  (nyxt::initialize-lparallel-kernel :worker-count 2)
  (unless (uiop:getenv "FONTCONFIG_FILE")
    (sb-posix:setenv "FONTCONFIG_FILE" "/etc/fonts/fonts.conf" 1))
  ;; Use upstream startup so user configuration, hooks and profile files have
  ;; their normal semantics. The renderer is the platform-specific extension.
  ;; Init already owns single-instance activation and the world control port.
  ;; Upstream supports a disabled socket via an empty virtual file.
  (setf nyxt:*socket-file*
    (make-instance 'files:file :base-path #p""
      :profile (make-instance 'files:virtual-profile)))
  (nyxt::start-browser urls)
  (when suggestions-supplied-p
    (setf (nyxt::search-engine-suggestions-p nyxt:*browser*) online-suggestions))
  nyxt:*browser*)
