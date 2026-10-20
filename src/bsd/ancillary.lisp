(in-package #:darterfly/bsd)

;; Queue ownership is independent of descriptor-table ownership. In-flight
;; senders retain references before sleeping. The queued-reference counts let
;; the collector distinguish external roots from Unix socket reference cycles.
(defvar *control-buffers* (make-hash-table :test 'eq))
(defvar *queued-files* (make-hash-table :test 'eq))
(defvar *collecting-controls* nil)
(defconstant +message-rights+ 253)
(defconstant +message-bytes+ 32768)

(defun release-control-files (files)
  (dolist (file files)
    (when (zerop (decf (file-refs file))) (file-close file))))

(defun note-control-files (files delta)
  (dolist (file files)
    (let ((count (+ delta (gethash file *queued-files* 0))))
      (if (zerop count) (remhash file *queued-files*)
          (setf (gethash file *queued-files*) count)))))

(defun buffer-control-files (buffer)
  (append (loop for item in (buffer-controls buffer) append (third item))
          (loop for item in (buffer-packets buffer) append (second item))))

(defun discard-local-buffer (buffer)
  (let ((files (buffer-control-files buffer)))
    (setf (buffer-controls buffer) nil (buffer-packets buffer) nil
          (buffer-packet-bytes buffer) 0 (fill-pointer (octets buffer)) 0)
    (remhash buffer *control-buffers*)
    (note-control-files files -1)
    (release-control-files files)
    (collect-local-controls)))

(defun collect-local-controls ()
  "Reclaim rights queued in sockets with no externally reachable owner."
  (unless *collecting-controls*
    (let ((*collecting-controls* t) (seen (make-hash-table :test 'eq))
          (buffers (loop for b being the hash-keys of *control-buffers* collect b)))
      (labels ((visit (file)
                 (unless (gethash file seen)
                   (setf (gethash file seen) t)
                   (when (typep file 'local-socket)
                     (when (local-input file)
                       (mapc #'visit (buffer-control-files (buffer (local-input file)))))
                     (mapc #'visit (local-queue file))))))
        (dolist (b buffers)
          (let ((owner (buffer-owner b)))
            (when (> (file-refs owner) (gethash owner *queued-files* 0))
              (visit owner))))
        (maphash (lambda (file count)
                   (when (> (file-refs file) count) (visit file))) *queued-files*)
        ;; Detaching all unreachable queues before dropping any references
        ;; prevents recursive close/shutdown from releasing the same rights.
        (let ((files nil))
          (dolist (b buffers)
            (unless (gethash (buffer-owner b) seen)
              (setf files (nconc (buffer-control-files b) files)
                    (buffer-controls b) nil (buffer-packets b) nil
                    (buffer-packet-bytes b) 0 (fill-pointer (octets b)) 0)
              (remhash b *control-buffers*)))
          (note-control-files files -1)
          (release-control-files files))))))

(defmethod descriptor-released ((file local-socket)) (collect-local-controls))

(defun local-queued-p (s)
  (let ((b (buffer (local-input s))))
    (if (= (socket-type s) 5) (not (null (buffer-packets b)))
        (plusp (length (octets b))))))

(defun local-room (s)
  (let ((b (buffer (local-output s))))
    (- +pipe-size+ (if (= (socket-type s) 5) (buffer-packet-bytes b)
                      (length (octets b))))))

(defun local-send (s data files flags)
  ;; FILES already carry one owned reference each. Ownership moves to the
  ;; queue only on a positive stream write or successful packet send.
  (unless (local-output s) (fail :enotconn))
  (let* ((b (buffer (local-output s))) (packet (= (socket-type s) 5))
         (n (length data)) (nowait (or (nonblocking-p s) (logtest flags #x40))))
    (when (and (not packet) (zerop n))
      (when files (fail :einval))
      (return-from local-send 0))
    (when (> n +pipe-size+) (fail :emsgsize))
    (labels ((broken ()
               (when (or (local-write-shut s) (zerop (readers b)))
                 (if (logtest flags #x4000) (fail :epipe) (broken-pipe))))
             (can-send ()
               (and (< (+ (length (buffer-controls b)) (length (buffer-packets b))) 256)
                    (<= (+ (length (buffer-control-files b)) (length files)) 1024)
                    (if packet (>= (local-room s) n) (plusp (local-room s))))))
      (sleep-until (lambda () (broken) (or (can-send) (and nowait (fail :eagain)))))
      (when (not packet) (setf n (min n (local-room s))))
      (if packet
          (progn
            (setf (buffer-packets b)
                  (nconc (buffer-packets b) (list (list (copy-seq data) files))))
            (incf (buffer-packet-bytes b) n))
          (progn
            (when files
              (setf (buffer-controls b)
                    (nconc (buffer-controls b)
                           (list (list (buffer-write-position b)
                                       (+ (buffer-write-position b) n) files)))))
            (append-pipe-octets b data 0 n)
            (incf (buffer-write-position b) n)))
      (when (or packet files) (setf (gethash b *control-buffers*) t))
      (note-control-files files 1)
      (changed)
      n)))

(defun local-receive (s count flags peek)
  "Return bytes, owned file references, message flags, and original byte count."
  (unless (local-input s) (fail :enotconn))
  (unless (<= 0 count +pipe-size+) (fail :einval))
  (when (and (zerop count) (/= (socket-type s) 5))
    (return-from local-receive (values #() nil 0 0)))
  (let* ((b (buffer (local-input s))) (packet (= (socket-type s) 5))
         (nowait (or (nonblocking-p s) (logtest flags #x40))))
    (sleep-until (lambda ()
                   (or (local-read-shut s) (local-queued-p s) (zerop (writers b))
                       (and nowait (fail :eagain)))))
    (when (or (local-read-shut s) (not (local-queued-p s)))
      (return-from local-receive (values #() nil 0 0)))
    (let (data files size (out-flags 0))
      (if packet
          (let* ((item (first (buffer-packets b))) (bytes (first item)))
            (setf size (length bytes) data (subseq bytes 0 (min count size))
                  files (second item) out-flags (if (< count size) #x20 0))
            (unless peek (pop (buffer-packets b)) (decf (buffer-packet-bytes b) size)))
          (let* ((bytes (octets b)) (n (min count (length bytes)))
                 (control (first (buffer-controls b)))
                 (position (buffer-read-position b)))
            (when (and control (< (first control) (+ position n)))
              (setf n (min n (- (second control) position)) files (third control))
              (unless peek (pop (buffer-controls b))))
            (setf data (subseq bytes 0 n) size n)
            (unless peek
              (replace bytes bytes :start2 n)
              (decf (fill-pointer bytes) n)
              (incf (buffer-read-position b) n))))
      (if peek
          (dolist (file files) (incf (file-refs file)))
          (note-control-files files -1))
      (unless (or (buffer-controls b) (buffer-packets b))
        (remhash b *control-buffers*))
      (changed)
      (values data files out-flags size))))

(defun send-message (fd data rights &optional (flags 0))
  (syscall
    (unless (and (zerop (logandc2 flags #x4040))
                 (<= (length rights) +message-rights+)) (fail :einval))
    (let* ((s (fd-socket fd))
           (files (mapcar #'fd-file rights)) (sent nil))
      (unless (typep s 'local-socket) (fail :eopnotsupp))
      (dolist (file files) (incf (file-refs file)))
      (unwind-protect
           (prog1 (local-send s data files flags) (setf sent t))
        (unless sent (release-control-files files))
        (collect-local-controls)))))

(defun receive-message (fd count capacity &optional (flags 0))
  (syscall
    (unless (and (zerop (logandc2 flags #x40000062))
                 (<= 0 capacity +message-rights+)) (fail :einval))
    (let ((s (fd-socket fd)))
      (unless (typep s 'local-socket) (fail :eopnotsupp))
      (multiple-value-bind (data files out-flags original)
          (local-receive s count flags (logtest flags 2))
        (let ((fds nil) (left files) (installed nil))
          (unwind-protect
               (progn
                 (loop while (and left (< (length fds) capacity)) do
                   (let ((fds-table (proc-fds *proc*)))
                     (when (and (>= (length fds-table) 4096)
                                (not (position nil fds-table :start 3 :end 4096)))
                       (return)))
                   (let ((new (fd-alloc (first left) 3)))
                     (pop left)
                     (setf (cdr (aref (proc-fds *proc*) new)) (logtest flags #x40000000))
                     (push new fds)))
                 (when left (setf out-flags (logior out-flags 8)))
                 (setf installed t)
                 (values data (reverse fds) out-flags
                         (if (and (= (socket-type s) 5) (logtest flags #x20))
                             original (length data))))
            (unless installed (dolist (n fds) (close n)))
            (release-control-files left)
            (collect-local-controls)))))))
