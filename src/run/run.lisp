(defpackage #:darterfly/run
  (:use #:cl)
  (:export #:run-core #:run-world #:start-world #:finish-world #:stop-world #:world-eval #:attach #:world-id #:world-name
           #:new-world #:list-worlds #:find-world #:save-world #:restart-world #:checkpoint-world #:restore-world #:restore-worlds #:*worlds-dir* #:collect #:tree-files #:in-run-p #:in-world-p #:no-room #:memory-use #:*system-reserve-mb*))
(in-package #:darterfly/run)

(defconstant +magic+ #x4e555248434e4946)
(defconstant +base+ #x0000340000000000)
(defconstant +header+ 120)
(defconstant +world-base+ #x0000400000000000)

(defun read-octets (path)
  (with-open-file (s path :element-type '(unsigned-byte 8))
    (let ((v (make-array (file-length s) :element-type '(unsigned-byte 8))))
      (read-sequence v s)
      v)))

(defun tree-files (dir &key (keep (constantly t)))
  (append (remove-if-not keep (uiop:directory-files dir))
          (mapcan (lambda (sub) (tree-files sub :keep keep)) (uiop:subdirectories dir))))

(defun pad4 (n) (logand (+ n 3) (lognot 3)))

(defun archive (files)
  (let* ((entries (loop :for file :in files :for i :from 1
                        :collect (list (namestring file) (read-octets file)
                                       (- (file-write-date file) 2208988800) i)))
         (entries (append entries (list (list "TRAILER!!!" (make-array 0 :element-type '(unsigned-byte 8)) 0 0))))
         (size (loop :for (name octets) :in entries
                     :sum (+ (pad4 (+ 110 (length name) 1)) (pad4 (length octets)))))
         (out (make-array size :element-type '(unsigned-byte 8) :initial-element 0))
         (at 0))
    (loop :for (name octets mtime ino) :in entries
          :do (let ((header (format nil "070701~{~8,'0x~}" (list ino (if (string= name "TRAILER!!!") 0 #o100644) 0 0 1 mtime
                                                                  (length octets) 0 0 0 0 (1+ (length name)) 0))))
                (loop :for c :across header :for i :from at :do (setf (aref out i) (char-code c)))
                (loop :for c :across name :for i :from (+ at 110) :do (setf (aref out i) (char-code c)))
                (incf at (pad4 (+ 110 (length name) 1)))
                (replace out octets :start1 at)
                (incf at (pad4 (length octets)))))
    out))

(defun c-strings (strings)
  (let ((octets (sb-ext:string-to-octets (format nil "~{~a~c~}" (loop :for s :in strings :append (list s (code-char 0))))
                                          :external-format :utf-8)))
    octets))

(defmacro libsa (name result &rest args)
  `(sb-alien:alien-funcall (sb-alien:extern-alien ,name (function ,result ,@(mapcar #'first args))) ,@(mapcar #'second args)))

(defun copy-in (address octets)
  (sb-sys:with-pinned-objects (octets)
    (libsa "memcpy" sb-sys:system-area-pointer
           (sb-sys:system-area-pointer (sb-sys:int-sap address))
           (sb-sys:system-area-pointer (sb-sys:vector-sap octets))
           (sb-alien:unsigned (length octets)))))

(defun page-up (n) (logand (+ n 4095) (lognot 4095)))

(defun u64-at (octets at) (loop :for i :below 8 :sum (ash (aref octets (+ at i)) (* 8 i))))
(defun u32-at (octets at) (loop :for i :below 4 :sum (ash (aref octets (+ at i)) (* 8 i))))
(defun u16-at (octets at) (loop :for i :below 2 :sum (ash (aref octets (+ at i)) (* 8 i))))

(defun elf-symbol (octets name)
  (let ((shoff (u64-at octets 40)) (size (u16-at octets 58)) (count (u16-at octets 60))
        (want (sb-ext:string-to-octets name)))
    (dotimes (i count)
      (let ((sh (+ shoff (* i size))))
        (when (= 2 (u32-at octets (+ sh 4)))
          (let* ((at (u64-at octets (+ sh 24))) (end (+ at (u64-at octets (+ sh 32))))
                 (strtab (u64-at octets (+ shoff (* (u32-at octets (+ sh 40)) size) 24))))
            (loop :for sym :from at :below end :by 24
                  :for start := (+ strtab (u32-at octets sym))
                  :when (and (= (aref octets (+ start (length want))) 0)
                             (equalp want (subseq octets start (+ start (length want)))))
                    :do (return-from elf-symbol (u64-at octets (+ sym 8))))))))))

(defun record-parts (core argv files cwd stdin kernel)
  (list (c-strings argv) (c-strings (list (or cwd "/")))
        (if stdin (c-strings (list stdin)) (make-array 0 :element-type '(unsigned-byte 8)))
        (archive files) (pathname core)
        (if kernel (read-octets kernel) (make-array 0 :element-type '(unsigned-byte 8)))))

(defun part-length (part)
  (if (pathnamep part)
      (with-open-file (s part :element-type '(unsigned-byte 8)) (file-length s))
      (length part)))

(defun copy-part (address part)
  (if (pathnamep part)
      (with-open-file (s part :element-type '(unsigned-byte 8))
        (let ((buffer (make-array (ash 1 20) :element-type '(unsigned-byte 8))))
          (loop :for n := (read-sequence buffer s)
                :while (plusp n)
                :do (copy-in address (if (= n (length buffer)) buffer (subseq buffer 0 n)))
                    (incf address n))))
      (copy-in address part)))

(defun layout (parts back-size)
  (let* ((offsets (let ((at +header+))
                    (loop :for p :in parts
                          :collect (setf at (page-up at))
                          :do (incf at (part-length p)))))
         (back-at (page-up (+ (car (last offsets)) (part-length (car (last parts)))))))
    (values offsets back-at (+ back-at back-size))))

(defun write-record (base size parts offsets back-at back-address back-size port &optional disk)
  (let ((region (libsa "mmap" sb-alien:unsigned (sb-alien:unsigned base) (sb-alien:unsigned size)
                       (sb-alien:int 3) (sb-alien:int #x32) (sb-alien:int -1) (sb-alien:long 0))))
    (unless (= region base) (error "run: no room at ~x" base))
    (loop :for p :in parts :for off :in offsets :do (copy-part (+ base off) p))
    (when (plusp back-size)
      (libsa "memcpy" sb-sys:system-area-pointer (sb-sys:system-area-pointer (sb-sys:int-sap (+ base back-at)))
             (sb-sys:system-area-pointer (sb-sys:int-sap back-address)) (sb-alien:unsigned back-size)))
    (destructuring-bind (argv cwd stdin archive core image) offsets
      (declare (ignore image))
      (let ((header (make-array 15 :element-type '(unsigned-byte 64) :initial-element 0)))
        (setf (aref header 0) +magic+
              (aref header 1) (+ base core) (aref header 2) (part-length (fifth parts))
              (aref header 3) (+ base argv) (aref header 4) (length (first parts))
              (aref header 5) (+ base archive) (aref header 6) (length (fourth parts))
              (aref header 7) (+ base cwd)
              (aref header 8) (if (plusp (length (third parts))) (+ base stdin) 0)
              (aref header 9) (+ base back-at) (aref header 10) back-size
              (aref header 13) port
              (aref header 14) (if disk 1 0))
        (sb-sys:with-pinned-objects (header)
          (libsa "memcpy" sb-sys:system-area-pointer (sb-sys:system-area-pointer (sb-sys:int-sap base))
                 (sb-sys:system-area-pointer (sb-sys:vector-sap header)) (sb-alien:unsigned +header+)))))))

(defun run-core (core argv &key files cwd stdin kernel)
  (let ((back (make-array 2 :element-type '(unsigned-byte 64))))
    (sb-sys:with-pinned-objects (back)
      (libsa "__libsa_core_range" sb-alien:int (sb-sys:system-area-pointer (sb-sys:vector-sap back))
             (sb-sys:system-area-pointer (sb-sys:sap+ (sb-sys:vector-sap back) 8))))
    (let ((parts (mapcar (lambda (p) (if (pathnamep p) (read-octets p) p)) (record-parts core argv files cwd stdin kernel))))
      (multiple-value-bind (offsets back-at size) (layout parts (aref back 1))
        (darterfly/vfs:vfs-sync)
        (let ((left (darterfly/install:stop-threads (list (sb-thread:main-thread)))))
          (when left (error "threads still running: ~a" left)))
        (sb-impl::finalizer-thread-stop)
        (write-record +base+ size parts offsets back-at (aref back 0) (aref back 1) 0)
        (let* ((image-octets (sixth parts))
               (entry (if kernel (or (elf-symbol image-octets "_libsa_start") (error "run: ~a has no _libsa_start" kernel)) 0))
               (image-at (if kernel (+ +base+ (sixth offsets)) 0)))
          (loop :repeat 100
                :do (libsa "__machdep5" sb-alien:long (sb-alien:long 19) (sb-alien:long +base+) (sb-alien:long size)
                           (sb-alien:long image-at) (sb-alien:long (length image-octets)) (sb-alien:long entry))
                    (sleep 0.05)))
        (error "run: the kernel would not restart; threads ~a" (sb-thread:list-all-threads))))))

(defvar *world-runs* 0)

(defparameter *worlds-dir* "/Users/darterfly/worlds/")

(defun wait-gone (world)
  (loop :repeat 200 :until (eq (darterfly/worlds:world-state world) :gone) :do (sleep 0.05)))

(defun serve-world (port world proc timeout)
  (let ((end (and timeout (+ (get-internal-real-time) (* timeout internal-time-units-per-second))))
        (code nil) (archive nil) (at 0)
        (m (make-array 65536 :element-type '(unsigned-byte 8))))
    (loop
      (handler-case
          (multiple-value-bind (n token) (darterfly/worlds:receive-into port m :timeout 1)
            (case (u64-at m 0)
              (1 (let ((request (subseq m 0 n)))
                   (sb-thread:make-thread
                    (lambda ()
                      (darterfly/worlds:reply token (if proc
                                                        (darterfly/bsd:serve-request proc request token)
                                                        (make-array 24 :element-type '(unsigned-byte 8) :initial-element 255))))
                    :name "world call")))
              (2 (setf code (u64-at m 8)
                       archive (make-array (u64-at m 16) :element-type '(unsigned-byte 8))
                       at 0)
                 (darterfly/worlds:reply token #(0)))
              (3 (when archive
                   (replace archive m :start1 at :start2 8 :end2 n)
                   (incf at (- n 8)))
                 (darterfly/worlds:reply token #(0)))
              (t (darterfly/worlds:reply token #(0))))
            (when (and archive (>= at (length archive)))
              (return (values code archive))))
        (darterfly/worlds:world-error ()
          (when (member (darterfly/worlds:world-state world) (quote (:stopped :gone))) (return nil))
          (when (and end (> (get-internal-real-time) end)) (return nil)))))))

(defparameter *attach-prelude*
  "(sb-thread:make-thread
    (lambda ()
      (let ((buf (make-array 65536 :element-type '(unsigned-byte 8)))
            (out (make-array 3 :element-type '(unsigned-byte 64)))
            (call (lambda (n a b c d e)
                    (sb-alien:alien-funcall
                     (sb-alien:extern-alien \"__machdep5\" (function sb-alien:long sb-alien:long sb-alien:unsigned-long sb-alien:unsigned-long
                                                                    sb-alien:unsigned-long sb-alien:unsigned-long sb-alien:unsigned-long))
                     n a b c d e))))
        (loop
          (let ((n (sb-sys:with-pinned-objects (buf out)
                     (funcall call 42 2 (sb-sys:sap-int (sb-sys:vector-sap buf)) 65536 (sb-sys:sap-int (sb-sys:vector-sap out)) 0))))
            (when (and (minusp n) (/= n -4)) (return))
            (when (plusp n)
            (let* ((token (aref out 0))
                   (text (sb-ext:octets-to-string buf :end n :external-format :utf-8))
                   (save (and (> (length text) 6) (string= \":save \" text :end2 6) (subseq text 6)))
                   (reply (sb-ext:string-to-octets
                           (if save
                               \"saving\"
                               (handler-case
                                   (let* ((values nil)
                                          (printed (with-output-to-string (*standard-output*)
                                                     (setf values (multiple-value-list (eval (read-from-string text)))))))
                                     (format nil \"~a~{~s~^ ~}\" printed values))
                                 (serious-condition (e)
                                   (format nil \"error: ~a~%~a\" e
                                           (with-output-to-string (s) (sb-debug:print-backtrace :stream s :count 15))))))
                           :external-format :utf-8)))
              (when (> (length reply) 60000) (setf reply (subseq reply 0 60000)))
              (sb-sys:with-pinned-objects (reply)
                (funcall call 43 token (sb-sys:sap-int (sb-sys:vector-sap reply)) (length reply) 0 0))
              (when save
                (let ((me sb-thread:*current-thread*))
                  (sb-thread:interrupt-thread (sb-thread:main-thread)
                                              (lambda ()
                                                (sb-thread:join-thread me :default nil)
                                                (sb-ext:save-lisp-and-die save))))
                (return))))))))
    :name \"attach\")")

(defun with-prelude (argv)
  (let ((at (or (position "--eval" argv :test #'string=) (position "--quit" argv :test #'string=) (length argv))))
    (append (subseq argv 0 at) (list "--eval" *attach-prelude*) (subseq argv at))))

(defstruct (world (:constructor make-world)) id inward thread name core stopping restarts command cwd disk base every memory)

(defvar *worlds* nil)
(defvar *worlds-lock* (sb-thread:make-mutex :name "worlds"))

(defun list-worlds ()
  (sb-thread:with-mutex (*worlds-lock*)
    (loop :for w :in *worlds*
          :collect (list :name (world-name w) :id (world-id w) :core (world-core w)
                         :state (darterfly/worlds:world-state (world-id w))))))

(defun find-world (name)
  (sb-thread:with-mutex (*worlds-lock*)
    (find name *worlds* :key #'world-name :test #'equal)))

(defun world-argv (&rest evals)
  (append (list "/System/Library/Kernels/kernel" "--core" "/System/Library/Kernels/darterfly.core"
                "--no-sysinit" "--no-userinit" "--disable-debugger")
          (loop :for e :in evals :append (list "--eval" e))))

(defun failed-p (result) (not (eql 0 (getf result :exit))))

(defparameter *system-reserve-mb* 256)

(define-condition no-room (error)
  ((wanted :initarg :wanted :reader no-room-wanted)
   (free :initarg :free :reader no-room-free)
   (promised :initarg :promised :reader no-room-promised)
   (using :initarg :using :reader no-room-using))
  (:report (lambda (c s)
             (format s "no room for a world of ~d MB: ~d MB free, ~d MB promised to running worlds, ~d MB kept for the system~@[; in use: ~{~a~^, ~}~]"
                     (no-room-wanted c) (no-room-free c) (no-room-promised c) *system-reserve-mb*
                     (no-room-using c)))))

(defun resident-mb (id)
  (or (getf (find id (darterfly/worlds:worlds) :key (lambda (w) (getf w :id))) :resident-mb) 0))

(defun memory-use ()
  (sb-thread:with-mutex (*worlds-lock*)
    (loop for w in *worlds*
          collect (list :name (world-name w)
                        :memory (world-memory w)
                        :resident (resident-mb (world-id w))))))

(defun room-for (memory)
  (let* ((free (round (* 4096 (darterfly/worlds:free-pages)) (* 1024 1024)))
         (use (memory-use))
         (promised (loop for w in use
                         for budget = (getf w :memory)
                         when budget sum (max 0 (- budget (getf w :resident))))))
    (when (> (+ memory promised *system-reserve-mb*) free)
      (error 'no-room
             :wanted memory :free free :promised promised
             :using (loop for w in use
                          collect (format nil "~a ~d MB~@[ of ~d~]" (getf w :name) (getf w :resident) (getf w :memory)))))
    t))

(defun with-memory (argv memory)
  (if memory
      (list* (first argv) "--dynamic-space-size" (format nil "~dMB" memory) (rest argv))
      argv))

(defun new-world (name &key (core "/usr/lib/sbcl/sbcl.core") (cwd "/") (evals (list "(loop (sleep 60))")) restart (restarts nil) checkpoint memory)
  (when (find-world name) (error "a world named ~a is already running" name))
  (let ((world (start-world core (apply #'world-argv evals) :cwd cwd :disk t :attach t :name name :memory memory)))
    (setf (world-restarts world) restarts)
    (when checkpoint
      (setf (world-every world) checkpoint)
      (ensure-directories-exist *worlds-dir*)
      (keep-checkpointed world))
    (when restart
      (sb-thread:make-thread
       (lambda ()
         (let ((result (finish-world world))
               (recent (remove-if (lambda (time) (< time (- (get-universal-time) 60))) restarts)))
           (when (and (not (world-stopping world)) (failed-p result) (< (length recent) 5))
             (sleep (if recent 2 0))
             (new-world name :core core :cwd cwd :evals evals :restart restart :memory memory
                             :restarts (cons (get-universal-time) recent)))))
       :name (format nil "supervise ~a" name)))
    world))

(defun save-world (world path)
  (world-eval world (concatenate 'string ":save " path))
  (finish-world world)
  (and (probe-file path) path))

(defun restart-world (name path &key (cwd "/"))
  (new-world name :core path :cwd cwd))

(defvar *bases* nil)

(defun free-base ()
  (sb-thread:with-mutex (*worlds-lock*)
    (loop :for slot :from 1 :below 16
          :for base := (+ +world-base+ (ash slot 36))
          :unless (member base *bases*)
            :do (push base *bases*) (return base)
          :finally (error "no room for another world"))))

(defun take-base (base)
  (sb-thread:with-mutex (*worlds-lock*)
    (when (member base *bases*) (error "the world at ~x is still running; stop it first" base))
    (push base *bases*)
    base))

(defun start-world (core argv &key files cwd stdin disk timeout attach name memory)
  (when memory (room-for memory))
  (let* ((argv (with-memory (if attach (with-prelude argv) argv) memory))
         (parts (record-parts core argv files cwd stdin nil))
         (base (free-base))
         (port (darterfly/worlds:make-port)))
    (multiple-value-bind (offsets back-at size) (layout parts 0)
      (write-record base size parts offsets back-at 0 0 1 disk)
      (multiple-value-bind (id inward) (darterfly/worlds:spawn-record base size port)
        (launch-world id inward port base size disk timeout
                      :name name :core core :argv argv :cwd cwd :memory memory)))))

(defun launch-world (id inward port base size disk timeout &key name core argv cwd memory)
  (let* ((proc (and disk (darterfly/bsd:make-world-proc (or cwd "/"))))
         (world (make-world :id id :inward inward :name (or name (format nil "world ~d" id)) :core core
                            :command argv :cwd cwd :disk disk :base base :memory memory)))
    (sb-thread:with-mutex (*worlds-lock*) (push world *worlds*))
    (setf (world-thread world)
          (sb-thread:make-thread
           (lambda ()
             (unwind-protect
                  (multiple-value-bind (code archive) (serve-world port id proc timeout)
                    (cond ((null code) (list :exit :stopped :files 0))
                          (t (sb-sys:with-pinned-objects (archive)
                               (let ((address (sb-sys:sap-int (sb-sys:vector-sap archive))))
                                 (if (zerop code)
                                     (list :exit 0 :files (unpack address (length archive)))
                                     (list :exit code :files 0 :rejected (count-entries address (length archive)))))))))
               (darterfly/worlds:stop id)
               (wait-gone id)
               (when proc (darterfly/bsd:end-world-proc proc))
               (libsa "munmap" sb-alien:int (sb-alien:unsigned base) (sb-alien:unsigned size))
               (sb-thread:with-mutex (*worlds-lock*)
                 (setf *worlds* (remove world *worlds*) *bases* (remove base *bases*)))))
           :name (format nil "world ~d" id)))
    world))

(defun checkpoint-world (world path &key full)
  (let ((fresh (or full (not (probe-file path)))))
    (with-open-file (out path :direction :output :element-type '(unsigned-byte 8)
                              :if-exists (if fresh :supersede :append) :if-does-not-exist :create)
      (when fresh
        (let ((meta (sb-ext:string-to-octets
                     (with-standard-io-syntax
                       (prin1-to-string (list :name (world-name world) :core (world-core world) :argv (world-command world)
                                              :cwd (world-cwd world) :disk (world-disk world) :base (world-base world)
                                              :checkpoint (world-every world))))
                     :external-format :utf-8)))
          (write-sequence (darterfly/worlds::u64-octets (length meta)) out)
          (write-sequence meta out)))
      (darterfly/worlds:checkpoint (world-id world) out :full fresh))))

(defun restore-world (path &key name)
  (with-open-file (in path :element-type '(unsigned-byte 8))
    (let* ((meta (let ((v (make-array (darterfly/worlds::read-count in 1) :element-type '(unsigned-byte 8))))
                   (read-sequence v in)
                   (with-standard-io-syntax
                     (let ((*read-eval* nil)) (read-from-string (sb-ext:octets-to-string v :external-format :utf-8))))))
           (base (getf meta :base))
           (name (or name (getf meta :name))))
      (when (find-world name) (error "a world named ~a is already running" name))
      (take-base base)
      (let ((parts (record-parts (getf meta :core) (getf meta :argv) nil (getf meta :cwd) nil nil))
            (port (darterfly/worlds:make-port)))
        (multiple-value-bind (offsets back-at size) (layout parts 0)
          (write-record base size parts offsets back-at 0 0 1 (getf meta :disk))
          (multiple-value-bind (id inward) (darterfly/worlds:restore in base size port)
            (let ((world (launch-world id inward port base size (getf meta :disk) nil
                                       :name name :core (getf meta :core) :argv (getf meta :argv) :cwd (getf meta :cwd))))
              (when (getf meta :checkpoint)
                (setf (world-every world) (getf meta :checkpoint))
                (keep-checkpointed world))
              world)))))))

(defun scheduled-p (path)
  (with-open-file (in path :element-type '(unsigned-byte 8))
    (let ((n (darterfly/worlds::read-u64 in)))
      (and (< 0 n 65536) (<= (+ 8 n) (file-length in))
           (let ((v (make-array n :element-type '(unsigned-byte 8))))
             (read-sequence v in)
             (getf (with-standard-io-syntax
                     (let ((*read-eval* nil)) (read-from-string (sb-ext:octets-to-string v :external-format :utf-8))))
                   :checkpoint))))))

(defun restore-worlds ()
  (loop :for file :in (directory (concatenate 'string *worlds-dir* "*.checkpoint"))
        :when (ignore-errors (scheduled-p file))
          :collect (handler-case (world-name (restore-world (namestring file)))
                     (serious-condition (e) (list (namestring file) (princ-to-string e))))))

(defun finish-world (world) (sb-thread:join-thread (world-thread world)))

(defun checkpoint-path (name) (format nil "~a~a.checkpoint" *worlds-dir* name))

(defun stop-world (world)
  (setf (world-stopping world) t)
  (darterfly/worlds:stop (world-id world))
  (prog1 (finish-world world)
    (when (world-every world) (ignore-errors (delete-file (checkpoint-path (world-name world)))))))

(defun keep-checkpointed (world)
  (sb-thread:make-thread
   (lambda ()
     (loop :for n :from 0
           :do (sleep (world-every world))
               (when (or (world-stopping world) (not (eq (darterfly/worlds:world-state (world-id world)) :running)))
                 (return))
               (handler-case
                   (if (and (plusp n) (zerop (mod n 50)))
                       (let ((fresh (concatenate 'string (checkpoint-path (world-name world)) ".new")))
                         (checkpoint-world world fresh :full t)
                         (rename-file fresh (checkpoint-path (world-name world))))
                       (checkpoint-world world (checkpoint-path (world-name world))))
                 (error (e) (format *error-output* "~&checkpoint of ~a: ~a~%" (world-name world) e)))))
   :name (format nil "checkpoint ~a" (world-name world))))

(defun run-world (core argv &rest keys &key files cwd stdin disk timeout)
  (declare (ignore files cwd stdin disk timeout))
  (finish-world (apply #'start-world core argv keys)))

(defun world-eval (world form)
  (sb-ext:octets-to-string (darterfly/worlds:call (world-inward world) (if (stringp form) form (prin1-to-string form)))
                           :external-format :utf-8))

(defun attach (world &key (input *standard-input*) (output *standard-output*))
  (loop
    (format output "~&world ~d> " (world-id world))
    (finish-output output)
    (let ((line (read-line input nil)))
      (when (or (null line) (string= (string-trim " " line) ":q")) (return))
      (unless (string= (string-trim " " line) "")
        (format output "~a~%" (handler-case (world-eval world line) (error (e) (format nil "world ~d: ~a" (world-id world) e))))))))

(defun in-world-p ()
  (/= 0 (libsa "__libsa_in_world" sb-alien:int)))

(defun in-run-p ()
  (/= 0 (libsa "__libsa_run_active" sb-alien:int)))

(defun count-entries (address size)
  (let ((sap (sb-sys:int-sap address)) (at 0) (n 0))
    (flet ((field (i) (parse-integer (map 'string (lambda (k) (code-char (sb-sys:sap-ref-8 sap (+ at 6 (* 8 i) k)))) '(0 1 2 3 4 5 6 7))
                                     :radix 16)))
      (loop :while (< (+ at 110) size)
            :do (let ((namesize (field 11)) (filesize (field 6)))
                  (when (string= "TRAILER!!!" (map 'string (lambda (k) (code-char (sb-sys:sap-ref-8 sap (+ at 110 k))))
                                                   (loop :for k :below (1- namesize) :collect k)))
                    (return))
                  (incf n)
                  (setf at (pad4 (+ (pad4 (+ at 110 namesize)) filesize))))))
    n))

(defun unpack (address end)
  (let ((sap (sb-sys:int-sap address)) (at 0) (files 0))
    (flet ((field (i) (parse-integer (map 'string (lambda (k) (code-char (sb-sys:sap-ref-8 sap (+ at 6 (* 8 i) k)))) '(0 1 2 3 4 5 6 7))
                                     :radix 16)))
      (loop :while (< (+ at 110) end)
            :do (let* ((mode (field 1)) (size (field 6)) (namesize (field 11))
                       (name (map 'string (lambda (k) (code-char (sb-sys:sap-ref-8 sap (+ at 110 k)))) (loop :for k :below (1- namesize) :collect k)))
                       (data (pad4 (+ at 110 namesize))))
                  (when (string= name "TRAILER!!!") (return))
                  (if (= (logand mode #o170000) #o040000)
                      (ensure-directories-exist (uiop:ensure-directory-pathname name))
                      (let ((v (make-array size :element-type '(unsigned-byte 8))))
                        (dotimes (k size) (setf (aref v k) (sb-sys:sap-ref-8 sap (+ data k))))
                        (ensure-directories-exist name)
                        (with-open-file (s name :direction :output :element-type '(unsigned-byte 8) :if-exists :supersede)
                          (write-sequence v s))
                        (incf files)))
                  (setf at (pad4 (+ data size))))))
    files))

(defun collect ()
  (let ((out (make-array 3 :element-type '(unsigned-byte 64))))
    (when (zerop (sb-sys:with-pinned-objects (out)
                   (libsa "__libsa_run_result" sb-alien:int
                          (sb-sys:system-area-pointer (sb-sys:vector-sap out))
                          (sb-sys:system-area-pointer (sb-sys:sap+ (sb-sys:vector-sap out) 8))
                          (sb-sys:system-area-pointer (sb-sys:sap+ (sb-sys:vector-sap out) 16)))))
      (return-from collect nil))
    (unless (zerop (aref out 2))
      (return-from collect (list :exit (aref out 2) :files 0 :rejected (count-entries (aref out 0) (aref out 1)))))
    (list :exit (aref out 2) :files (unpack (aref out 0) (aref out 1)))))
