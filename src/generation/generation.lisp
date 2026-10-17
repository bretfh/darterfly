(defpackage #:darterfly/generation
  (:use #:cl)
  (:export #:resume #:contrib-steps #:core-steps #:generation-steps #:*state* #:start #:progress #:pending-build #:resume-build))
(in-package #:darterfly/generation)

(defvar *state* "/Users/darterfly/generation.state")

(defvar *kernel* "/System/Library/Kernels/kernel")

(defvar *run-core* "/System/Library/Kernels/darterfly.core")

(defvar *contrib-script* "/usr/src/darterfly/src/generation/contrib.lisp")

(defvar *runtime* nil)

(defun on-runtime (kernel steps)
  (mapcar (lambda (step)
            (destructuring-bind (name kind thunk . rest) step
              (list* name kind (lambda () (let ((*runtime* kernel)) (funcall thunk))) rest)))
          steps))

(defun state ()
  (when (probe-file *state*)
    (with-open-file (s *state*)
      (loop :for line := (read s nil s) :until (eq line s) :collect line))))

(defun note (&rest entry)
  (with-open-file (s *state* :direction :output :if-exists :append :if-does-not-exist :create)
    (with-standard-io-syntax (prin1 entry s) (terpri s)))
  (darterfly/vfs:vfs-sync))

(defun step-name (step) (first step))

(defun missing (step)
  (remove-if #'probe-file (getf (cdddr step) :outputs)))

(defun resume (steps)
  (let* ((state (state))
         (last (car (last state))))
    (when (eq (first last) :running)
      (let* ((result (darterfly/run:collect))
             (step (find (second last) steps :key #'step-name :test #'string=))
             (missing (and step (missing step))))
        (if (and result (eql 0 (getf result :exit)) (null missing))
            (note :done (second last) result)
            (progn (note :failed (second last) result missing)
                   (return-from resume (list :failed (second last) result missing))))))
    (let ((done (loop :for (kind name) :in (state) :when (eq kind :done) :collect name)))
      (dolist (step steps (progn (note :finished (length done)) (list :done (length done))))
        (unless (member (step-name step) done :test #'string=)
          (destructuring-bind (name kind thunk &key outputs) step
            (mapc #'uiop:delete-file-if-exists outputs)
            (handler-case
                (ecase kind
                  (:run (note :running name) (funcall thunk))
                  (:lisp (let ((result (funcall thunk)))
                           (if (and result (null (missing step)))
                               (progn (note :done name result) (push name done))
                               (progn (note :failed name result (missing step))
                                      (return-from resume (list :failed name result (missing step))))))))
              (error (e)
                (let ((text (princ-to-string e)))
                  (note :failed name text)
                  (return-from resume (list :failed name text)))))))))))

(defun contrib-files (root)
  (append (list (pathname *contrib-script*))
          (mapcan (lambda (dir) (when (probe-file dir) (darterfly/run:tree-files dir)))
                  (list (concatenate 'string root "contrib/")
                        (concatenate 'string root "obj/sbcl-home/")
                        (concatenate 'string root "obj/from-self/")))))

(defun sbcl-run (root core cwd &rest args)
  (darterfly/run:run-core core (list* *kernel* "--core" *run-core* "--noinform" "--disable-debugger" "--no-sysinit" "--no-userinit" args)
                      :kernel *runtime*
                      :cwd (concatenate 'string root cwd) :files (contrib-files root)))

(defun asdf-step (root core name)
  (let ((fasl (format nil "~aobj/sbcl-home/contrib/~a.fasl" root name)))
    (list name :run
          (lambda ()
            (sbcl-run root core "contrib/asdf"
                      "--eval" (format nil "(setf sb-sys::*sbcl-homedir-pathname* #p~s)" (concatenate 'string root "obj/sbcl-home/"))
                      "--eval" "(setf (sb-ext:readtable-base-char-preference *readtable*) :both)"
                      "--eval" (format nil "(progn (ensure-directories-exist ~s) (compile-file #p\"SYS:CONTRIB;ASDF;~:@(~a~).LISP\" :print nil :output-file ~s))"
                                       fasl name fasl)
                      "--quit"))
          :outputs (list fasl))))

(defun contrib-step (root core name &rest requires)
  (let ((script *contrib-script*))
    (list name :run
          (lambda ()
            (apply #'sbcl-run root core (format nil "contrib/~a" name)
                   "--load" script name (mapcar (lambda (r) (format nil "~a.fasl" r)) requires)))
          :outputs (list (format nil "~aobj/sbcl-home/contrib/~a.fasl" root name)))))

(defun grovel-step (root name)
  (let ((dir (format nil "~aobj/from-self/contrib/~a/" root name)))
    (list (format nil "~a-grovel" name) :lisp
          (lambda ()
            (darterfly/cc:run-c (concatenate 'string dir "runme.c")
                            :args (list (concatenate 'string dir "generated-constants.lisp")))
            (probe-file (concatenate 'string dir "generated-constants.lisp"))))))

(defun contrib-steps (root &optional (core (concatenate 'string root "output/sbcl.core")))
  (list (asdf-step root core "uiop")
        (asdf-step root core "asdf")
        (contrib-step root core "sb-rotate-byte")
        (contrib-step root core "sb-md5" "sb-rotate-byte")
        (list "sb-posix-c" :run (let ((pass (third (contrib-step root core "sb-posix"))))
                                 (lambda ()
                                   (uiop:delete-file-if-exists (format nil "~aobj/from-self/contrib/sb-posix/generated-constants.lisp" root))
                                   (funcall pass)))
              :outputs (list (format nil "~aobj/from-self/contrib/sb-posix/runme.c" root)))
        (grovel-step root "sb-posix")
        (contrib-step root core "sb-posix")
        (list "sb-bsd-sockets-c" :run (let ((pass (third (contrib-step root core "sb-bsd-sockets"))))
                                 (lambda ()
                                   (uiop:delete-file-if-exists (format nil "~aobj/from-self/contrib/sb-bsd-sockets/generated-constants.lisp" root))
                                   (funcall pass)))
              :outputs (list (format nil "~aobj/from-self/contrib/sb-bsd-sockets/runme.c" root)))
        (grovel-step root "sb-bsd-sockets")
        (contrib-step root core "sb-bsd-sockets")))

(defun core-steps (root out &optional (core (concatenate 'string root "output/sbcl.core")))
  (list (list "darterfly.core" :run
              (lambda ()
                (darterfly/run:run-core
                 core
                 (list *kernel* "--core" *run-core* "--noinform" "--disable-debugger" "--no-sysinit" "--no-userinit"
                       "--eval" (format nil "(setf sb-sys::*sbcl-homedir-pathname* #p~s)" (concatenate 'string root "obj/sbcl-home/"))
                       "--eval" "(require :asdf)"
                       "--eval" "(asdf:initialize-source-registry '(:source-registry (:tree \"/usr/src/darterfly/\") (:tree \"/usr/share/common-lisp/sbcl/\") :ignore-inherited-configuration))"
                       "--eval" (format nil "(ensure-directories-exist ~s)" out)
                       "--load" "/usr/src/darterfly/src/image/darterfly-core.lisp" out)
                 :cwd "/Users/darterfly"
                 :kernel *runtime*
                 :files (append (darterfly/run:tree-files "/usr/src/darterfly/")
                                (darterfly/run:tree-files "/usr/share/common-lisp/sbcl/")
                                (darterfly/run:tree-files (concatenate 'string root "obj/sbcl-home/")))))
              :outputs (list out))))

(defvar *darterfly-core* "/System/Library/Kernels/darterfly.core")

(defun phase-step (name sbcl form &rest outputs)
  (list* name :run
        (lambda ()
          (darterfly/run:run-core
           *darterfly-core*
           (list *kernel* "--core" *run-core* "--disable-debugger"
                 "--eval" (format nil "(progn (setf *default-pathname-defaults* #p~s) (load \"loader.lisp\"))" sbcl)
                 "--eval" form
                 "--eval" "(funcall (intern \"VFS-SYNC\" (or (find-package \"HOST-DARTERFLY/VFS\") (find-package \"DARTERFLY/VFS\"))))"
                 "--quit")
           :cwd sbcl))
        (when outputs (list :outputs outputs))))

(defun target-files (sbcl)
  (darterfly/run:tree-files sbcl :keep (lambda (f) (let ((n (namestring f)))
                                                 (not (or (search "/obj/from-host/" n) (search "/obj/from-xc/" n)
                                                          (search "/obj/sbcl-home/" n) (search ".core" n)))))))

(defun dump-script (sbcl)
  (let* ((script (uiop:read-file-string (concatenate 'string sbcl "make-target-2.sh")))
         (start (+ (search (format nil "<<EOF~%") script) 6))
         (body (subseq script start (1+ (search (format nil "~%EOF") script :start2 start))))
         (at (search "${devel}" body)))
    (concatenate 'string (subseq body 0 at) (subseq body (+ at 8)))))

(defun source-build-id (sbcl darterfly)
  (let ((trees (list (darterfly/build:digest-tree (concatenate 'string sbcl "src/")
                                              :keep (lambda (f) (not (or (search "/runtime/genesis/" (namestring f))
                                                                         (member (pathname-type f) '("o" "d") :test #'equal)))))
                     (darterfly/build:digest-tree (concatenate 'string darterfly "src/sbcl/"))
                     (darterfly/build:digest-tree (concatenate 'string darterfly "src/libsa/"))
                     (darterfly/build:digest (concatenate 'string darterfly "src/build/build.lisp")))))
    (format nil "darterfly-~(~{~2,'0x~}~)" (coerce (subseq (sb-md5:md5sum-string (prin1-to-string trees)) 0 8) 'list))))

(defun runtime-build-id ()
  (let ((sap (sb-sys:int-sap (sb-sys:find-foreign-symbol-address "build_id"))))
    (map 'string #'code-char (loop :for i :from 0 :for b := (sb-sys:sap-ref-8 sap i) :until (zerop b) :collect b))))

(defun write-octets (path octets)
  (ensure-directories-exist path)
  (with-open-file (s path :direction :output :element-type '(unsigned-byte 8) :if-exists :supersede)
    (write-sequence octets s))
  path)

(defun generation-steps (&key (sbcl "/usr/src/sbcl/") (darterfly "/usr/src/darterfly/") (tinycc "/usr/src/tinycc/")
                              (out "/Users/darterfly/generation/"))
  (flet ((in (root path) (concatenate 'string root path)))
    (let ((cold (in sbcl "output/cold-sbcl.core"))
          (runtime (in darterfly "build/runtime/"))
          (objects (in out "objects/"))
          (kernel (in out "kernel")))
      (flet ((runtime-tree ()
               (darterfly/build:runtime-tree sbcl (in darterfly "src/sbcl/") runtime)))
        (append
         (list (list "config" :lisp
                     (lambda ()
                       (let ((id (source-build-id sbcl darterfly)))
                         (darterfly/build:write-files sbcl (darterfly/build:sbcl-config id))
                         id)))
               (phase-step "make-host-1" sbcl "(cl-user::load-sbcl-file \"make-host-1.lisp\" nil)")
               (list "grovel" :lisp
                     (lambda ()
                       (runtime-tree)
                       (eql 0 (darterfly/cc:run-c "tools-for-build/grovel-headers.c" :directory sbcl
                                              :includes (list (in runtime "src/runtime/"))
                                              :output (in sbcl "output/stuff-groveled-from-headers.lisp")))))
               (phase-step "make-host-2" sbcl "(progn (push (lambda () (throw 'after-xc t)) sb-ext:*save-hooks*) (catch 'after-xc (cl-user::load-sbcl-file \"make-host-2.lisp\" nil)))")
               (phase-step "make-genesis-2" sbcl "(cl-user::load-sbcl-file \"make-genesis-2.lisp\" nil)" cold)
               (list "objects" :lisp
                     (lambda ()
                       (ensure-directories-exist out)
                       (runtime-tree)
                       (let ((tccdefs (in out "tccdefs_.h")))
                         (darterfly/cc:run-c "conftest.c" :directory tinycc :defines '("C2STR")
                                         :args (list "include/tccdefs.h" tccdefs))
                         (darterfly/build:libtcc-tree tinycc (in darterfly "build/tcc/darterfly-src/") tccdefs))
                       (null (darterfly/cc:compile-units objects :directory darterfly))))
               (list "kernel" :lisp
                     (lambda () (darterfly/install:build-kernel :objects objects :out kernel))
                     :outputs (list kernel)))
         (on-runtime
          kernel
          (append
           (list (list "warm" :run
                       (lambda ()
                         (darterfly/run:run-core cold (list *kernel* "--core" *run-core* "--lose-on-corruption" "--no-sysinit" "--no-userinit"
                                                        "--eval" "(sb-fasl::!warm-load \"src/cold/warm.lisp\")" "--quit")
                                             :cwd (string-right-trim "/" sbcl) :files (target-files sbcl) :kernel *runtime*)))
                 (list "sbcl.core" :run
                       (lambda ()
                         (let ((stdin (in sbcl "output/target-2-dump.lisp")))
                           (with-open-file (s stdin :direction :output :if-exists :supersede)
                             (write-string (dump-script sbcl) s))
                           (darterfly/run:run-core cold (list *kernel* "--noinform" "--core" *run-core* "--lose-on-corruption"
                                                          "--no-sysinit" "--no-userinit" "--noprint")
                                               :cwd (string-right-trim "/" sbcl) :files (target-files sbcl) :stdin stdin
                                               :kernel *runtime*)))
                       :outputs (list (in sbcl "output/sbcl.core"))))
           (contrib-steps sbcl)
           (core-steps sbcl (in out "darterfly.core"))))
         (list (list "boot.efi" :lisp
                     (lambda () (write-octets (in out "boot.efi") (darterfly/boot:boot-image))))
               (list "manifest" :lisp
                     (lambda ()
                       (darterfly/build:write-manifest
                        (in out "manifest")
                        (darterfly/build:manifest
                         :build-id (string-trim '(#\" #\Newline) (uiop:read-file-string (in sbcl "output/build-id.inc")))
                         :parent (ignore-errors (darterfly/install:current))
                         :sources (list (list "darterfly" (in darterfly "src/")) (list "sbcl" (in sbcl "src/"))
                                        (list "contrib" (in sbcl "contrib/")) (list "tinycc" tinycc)
                                        (list "libraries" "/usr/share/common-lisp/sbcl/"))
                         :outputs (list (list "kernel" kernel) (list "darterfly.core" (in out "darterfly.core"))
                                        (list "boot.efi" (in out "boot.efi")))))))
               (list "install" :lisp
                     (lambda ()
                       (darterfly/install:install kernel (in out "darterfly.core")
                                              :loader (in out "boot.efi") :manifest (in out "manifest"))))))))))

(defun build-arguments ()
  (rest (find :build (state) :key #'first)))

(defun next-out ()
  (format nil "/Users/darterfly/generation-~d/"
          (1+ (reduce #'max (darterfly/install:generations) :key (lambda (g) (parse-integer g :start 4)) :initial-value 0))))

(defun resume-build ()
  (let ((args (build-arguments)))
    (sb-thread:make-thread (lambda ()
                             (let ((result (resume (generation-steps :out (getf args :out)))))
                               (format t "~&generation build: ~s~%" result)
                               (finish-output)))
                           :name "generation build")))

(defun start (&key (out (next-out)))
  (uiop:delete-file-if-exists *state*)
  (note :build :out out :auto t)
  (resume-build))

(defun pending-build ()
  (let ((state (state)))
    (and (getf (build-arguments) :auto)
         (not (find :finished state :key #'first))
         (not (eq :failed (first (car (last state))))))))

(defun progress ()
  (let* ((state (state))
         (args (build-arguments))
         (names (mapcar #'step-name (generation-steps :out (or (getf args :out) "/Users/darterfly/generation/")))))
    (when state
      (list :out (getf args :out)
            :finished (and (find :finished state :key #'first) t)
            :steps (loop :for name :in names
                         :collect (list name (let ((entry (find name state :key #'second :test #'equal :from-end t)))
                                               (if entry (first entry) :waiting))))))))
