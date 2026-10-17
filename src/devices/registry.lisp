(in-package #:darterfly/devices)

(defvar *device-classes* (make-hash-table :test 'equal))

(defmacro define-device-class (name registry-name supers &optional slots)
  `(progn
     (defclass ,name ,supers ,slots)
     (setf (gethash ,registry-name *device-classes*) ',name
           (get ',name 'device-class-name) ,registry-name)
     ',name))

(defun device-class-name (entry) (get (class-name (class-of entry)) 'device-class-name))
(defun find-device-class (registry-name) (gethash registry-name *device-classes*))

(define-device-class entry "RegistryEntry" ()
  ((name :initarg :name :initform nil :accessor %entry-name)
   (location :initarg :location :initform nil :accessor entry-location)
   (properties :initform (make-hash-table :test 'equal) :reader entry-properties)
   (parent :initform nil :accessor entry-parent)
   (children :initform nil :accessor entry-children)))

(defun entry-name (entry) (or (%entry-name entry) (device-class-name entry)))
(defun (setf entry-name) (name entry) (setf (%entry-name entry) name))

(defun get-property (entry key) (gethash key (entry-properties entry)))
(defun set-property (entry key value) (setf (gethash key (entry-properties entry)) value))

(defun attach (child parent)
  (setf (entry-parent child) parent)
  (setf (entry-children parent) (append (entry-children parent) (list child)))
  child)

(defvar *device-hooks* nil)

(defun announce (event device)
  (dolist (hook *device-hooks*)
    (handler-case (funcall hook event device)
      (error (e) (format *error-output* "~&device ~(~a~) ~a: ~a~%" event (entry-name device) e)))))

(defun detach (child)
  (let ((parent (entry-parent child)))
    (when parent
      (setf (entry-children parent) (remove child (entry-children parent))
            (entry-parent child) nil))))

(define-device-class device "Service" (entry)
  ((provider :initform nil :accessor provider)))

(defgeneric start (service provider)
  (:method ((service device) provider) (declare (ignore provider)) t))

(defgeneric match-property-table (service table)
  (:method ((service device) table) (declare (ignore table)) t))

(defvar *registry-root* nil)
(defvar *personalities* nil)

(defun personality (&rest kv)
  (let ((h (make-hash-table :test 'equal)))
    (loop for (k v) on kv by #'cddr do (setf (gethash k h) v))
    h))

(defun property-match-p (service table)
  (flet ((all (want)
           (loop for k being the hash-keys of want using (hash-value v)
                 always (equal (get-property service k) v))))
    (let ((want (gethash "PropertyMatch" table)))
      (cond ((null want) t)
            ((listp want) (some #'all want))
            (t (all want))))))

(defun matches-p (personality service)
  (let ((class (find-device-class (gethash "ProviderClass" personality))))
    (and class (typep service class)
         (property-match-p service personality)
         (match-property-table service personality))))

(defun probe-score (personality) (or (gethash "ProbeScore" personality) 0))

(defun register-service (service)
  (dolist (p (stable-sort (copy-list (remove-if-not (lambda (p) (matches-p p service)) *personalities*)) #'> :key #'probe-score))
    (let ((driver (make-instance (find-device-class (gethash "Class" p)))))
      (maphash (lambda (k v) (set-property driver k v)) p)
      (set-property driver "MatchCategory" "DefaultMatchCategory")
      (setf (provider driver) service)
      (attach driver service)
      (if (start driver service)
          (return driver)
          (detach driver)))))

(defun find-entries (class &optional (root *registry-root*))
  (let ((found nil))
    (labels ((walk (e)
               (when (typep e class) (push e found))
               (mapc #'walk (entry-children e))))
      (walk root))
    (nreverse found)))

(defun device-tree (&optional (stream *standard-output*) (root *registry-root*))
  (labels ((walk (e prefix last)
             (format stream "~a~a~a~@[@~a~]  <class ~a>~%"
                     prefix (if (eq e root) "" "+-o ") (entry-name e) (entry-location e) (device-class-name e))
             (let ((children (entry-children e))
                   (inner (if (eq e root) "" (concatenate 'string prefix (if last "  " "| ")))))
               (loop for (c . more) on children
                     do (walk c inner (null more))))))
    (walk root "" t))
  (values))
