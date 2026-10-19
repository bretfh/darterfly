(in-package #:darterfly/layer)

(defun encode (form)
  (sb-ext:string-to-octets (with-standard-io-syntax
                             (let ((*print-readably* nil)
                                   (*package* (find-package :keyword)))
                               (prin1-to-string form)))
                           :external-format :utf-8))

(defun decode (octets)
  (if (zerop (length octets))
      nil
      (with-standard-io-syntax
        (let ((*read-eval* nil)
              (*package* (find-package :keyword)))
          (read-from-string (sb-ext:octets-to-string octets :external-format :utf-8))))))

(defvar *window-service* nil)
(defvar *window-service-lock* (sb-thread:make-mutex :name "window service"))

(defun window-service ()
  (sb-thread:with-mutex (*window-service-lock*)
    (or *window-service*
        (setf *window-service* (darterfly/run:look-up "windowserver")))))

(defun remote-request (body)
  (decode (darterfly/worlds:call (window-service) (encode body) :timeout nil)))

(defun pump-events (context)
  (let ((events (context-events context)))
    (loop
      (let ((event (handler-case (remote-request (list :next-event :context (context-id context) :timeout 1000))
                     (error () (sleep 1) nil))))
        (when event
          (darterfly/mach:mach-msg-send (darterfly/mach:make-message :remote-port events :body event)))))))

(defun remote-context-create ()
  (let ((events (darterfly/mach:mach-port-allocate darterfly/mach:*task* :receive))
        (id (getf (remote-request (list :context-create)) :context-id)))
    (darterfly/mach:mach-port-set-attributes darterfly/mach:*task* events :limits-info 1024)
    (darterfly/mach:mach-port-insert-right darterfly/mach:*task* events events :make-send)
    (let ((context (make-instance 'context :id id :port nil :events events)))
      (sb-thread:make-thread (lambda () (pump-events context))
                             :name (format nil "events ~d" id))
      context)))

(defun pixels-of (layers)
  (loop :for (nil . object) :in layers
        :for pixels := (getf (getf object :contents) :pixels)
        :when pixels :collect pixels))

(defun call-pinned (objects thunk)
  (if objects
      (sb-sys:with-pinned-objects ((first objects))
        (call-pinned (rest objects) thunk))
      (funcall thunk)))

(defun placed (layers)
  (loop :for (id . object) :in layers
        :for contents := (getf object :contents)
        :for pixels := (getf contents :pixels)
        :collect (cons id
                       (if pixels
                           (let ((copy (copy-list object)))
                             (setf (getf copy :contents)
                                   (list :width (getf contents :width)
                                         :height (getf contents :height)
                                         :at (sb-sys:sap-int (sb-sys:vector-sap pixels))
                                         :length (length pixels)))
                             copy)
                           object))))

(defun remote-commit (context root layers)
  (call-pinned (pixels-of layers)
               (lambda ()
                 (remote-request (list :commit :context (context-id context) :root root
                                       :layers (placed layers))))))

(defclass world-client ()
  ((world :initarg :world :reader client-world)
   (bindings :initarg :bindings :reader client-bindings)
   (contexts :initform nil :accessor client-contexts)
   (lock :initform (sb-thread:make-mutex :name "world client") :reader client-lock)))

(defvar *world-clients* (make-hash-table))
(defvar *world-clients-lock* (sb-thread:make-mutex :name "world clients"))

(defun world-client (world)
  (sb-thread:with-mutex (*world-clients-lock*)
    (or (gethash world *world-clients*)
        (setf (gethash world *world-clients*)
              (make-instance 'world-client :world world :bindings (darterfly/bsd::fresh-bindings))))))

(defun client-context (client id)
  (sb-thread:with-mutex ((client-lock client))
    (find id (client-contexts client) :key #'context-id)))

(defun fetched (layers token)
  (loop :for (id . object) :in layers
        :for contents := (getf object :contents)
        :collect (cons id
                       (if (getf contents :at)
                           (let ((pixels (make-array (getf contents :length) :element-type '(unsigned-byte 8)))
                                 (copy (copy-list object)))
                             (sb-sys:with-pinned-objects (pixels)
                               (darterfly/worlds:copy-from token (getf contents :at)
                                                           (sb-sys:sap-int (sb-sys:vector-sap pixels))
                                                           (length pixels)))
                             (setf (getf copy :contents)
                                   (image (getf contents :width) (getf contents :height) pixels))
                             copy)
                           object))))

(defun serve-window-request (client body token)
  (destructuring-bind (op &rest args) body
    (ecase op
      (:context-create
       (let ((context (local-context-create)))
         (sb-thread:with-mutex ((client-lock client))
           (push context (client-contexts client)))
         (list :context-id (context-id context))))
      (:commit
       (let ((context (client-context client (getf args :context))))
         (when context
           (send-commit (context-port context) (getf args :root) (fetched (getf args :layers) token)))
         nil))
      (:create-window
       (let ((context (client-context client (getf args :context))))
         (list :window (and context
                            (local-window-create context (getf args :x) (getf args :y)
                                                 (getf args :width) (getf args :height)
                                                 (getf args :level) (getf args :order))))))
      (:next-event
       (let ((context (client-context client (getf args :context))))
         (if context
             (next-event context :timeout (getf args :timeout))
             (progn (sleep 1) nil))))
      (:transaction
       (local-request body)
       nil)
      (:display-bounds
       (local-request body :reply t)))))

(defun serve-world-window-request (world proc request token)
  (let ((client (world-client world)))
    (darterfly/bsd::call-with-bindings
     (client-bindings client)
     (lambda ()
       (let ((darterfly/bsd:*proc* proc))
         (encode (serve-window-request client (decode request) token)))))))

(defun forget-world-client (world)
  (let ((client (sb-thread:with-mutex (*world-clients-lock*)
                  (prog1 (gethash world *world-clients*)
                    (remhash world *world-clients*)))))
    (when client
      (dolist (context (client-contexts client))
        (ignore-errors (darterfly/mach:mach-port-deallocate darterfly/mach:*task* (context-port context)))
        (ignore-errors (darterfly/mach:mach-port-mod-refs darterfly/mach:*task* (context-events context) :receive -1))))))

(darterfly/run:offer-service "windowserver" #'serve-world-window-request :gone #'forget-world-client)
