(in-package #:darterfly/test)

(def-suite install :in host)
(in-suite install)

(defstruct reload-probe a b)
(defclass reload-class () ())
(defconstant +reload-constant+ 3)

(defun hazards-of (text)
  (let ((file (merge-pathnames "reload-probe.lisp" (scratch))))
    (with-open-file (s file :direction :output :if-exists :supersede)
      (write-string "(in-package #:darterfly/test)" s) (terpri s) (write-string text s))
    (darterfly/install::reload-hazards (list (namestring file)))))

(test reloading-only-safe-definitions-is-allowed
  (is (null (hazards-of "(defstruct reload-probe a b) (defclass reload-class () ((x))) (defconstant +reload-constant+ 3) (defun f () 1)")))
  (is (null (hazards-of "(defstruct brand-new-struct x) (defconstant +brand-new-constant+ 9)"))))

(test reload-hazards-are-caught-before-loading
  (is (search "changes its slots" (first (hazards-of "(defstruct reload-probe a b c)"))))
  (is (search "a class can't take its name" (first (hazards-of "(defclass reload-probe () ())"))))
  (is (search "a struct can't take its name" (first (hazards-of "(defstruct reload-class x)"))))
  (is (search "changes from 3 to 4" (first (hazards-of "(defconstant +reload-constant+ 4)")))))

(test a-kernel-layout-constant-goes-through-a-deploy
  (let ((name (intern "+DEPLOY-PROBE+" "DARTERFLY/KERN")))
    (unless (boundp name) (eval `(defconstant ,name 1)))
    (is (null (darterfly/install::form-hazard `(defconstant ,name 2))) "the new kernel comes with it, so it isn't a hazard")
    (handler-bind ((error #'darterfly/install::take-kernel-constant))
      (eval `(defconstant ,name 2)))
    (is (= 2 (symbol-value name)) "and the reload takes the new value")
    (eval `(handler-bind ((error #'darterfly/install::take-kernel-constant)) (defconstant ,name 1)))))

(test a-symbol-a-deploy-only-read-gives-way-to-a-new-export
  (let ((from (or (find-package "DEPLOY-PROBE-FROM") (make-package "DEPLOY-PROBE-FROM" :use '(:cl))))
        (to (or (find-package "DEPLOY-PROBE-TO") (make-package "DEPLOY-PROBE-TO" :use '(:cl)))))
    (use-package from to)
    (intern "READ-ONLY" to)
    (let ((used (intern "USED" to)))
      (setf (symbol-function used) (lambda () t)))
    (handler-bind ((sb-ext:name-conflict #'darterfly/install::take-exported-symbol))
      (export (intern "READ-ONLY" from) from))
    (is (eq (find-symbol "READ-ONLY" to) (find-symbol "READ-ONLY" from)) "a symbol the hazard check only read gives way")
    (is (eq :refused (handler-case (handler-bind ((sb-ext:name-conflict #'darterfly/install::take-exported-symbol))
                                     (export (intern "USED" from) from))
                       (sb-ext:name-conflict () :refused)))
        "one with a definition is left for a person")
    (delete-package to)
    (delete-package from)))

(test forms-typed-since-the-last-save-are-kept-and-replayable
  (let ((darterfly/journal:*journal* (namestring (merge-pathnames "forms" (scratch)))))
    (uiop:delete-file-if-exists darterfly/journal:*journal*)
    (darterfly/journal:note-form "(defvar cl-user::*journal-a* 1)" :origin :listener)
    (darterfly/journal:note-save)
    (darterfly/journal:note-form "(defvar cl-user::*journal-b* 2) (defvar cl-user::*journal-c* (+ cl-user::*journal-b* 1))" :origin :nrepl)
    (darterfly/journal:note-form "(error \"boom\")" :origin :listener)
    (let ((since (darterfly/journal:forms-since-save)))
      (is (= 2 (length since)) "only what came after the save")
      (let ((results (darterfly/journal:replay since)))
        (is (eq :ok (third (first results))))
        (is (= 3 (symbol-value 'cl-user::*journal-c*)))
        (is (eq :error (first (third (second results)))) "a failing form is reported, not fatal")))))

(test an-installed-save-trims-the-journal-to-what-came-after-it
  (let ((darterfly/journal:*journal* (namestring (merge-pathnames "forms-trim" (scratch)))))
    (uiop:delete-file-if-exists darterfly/journal:*journal*)
    (darterfly/journal:note-form "(+ 1 1)")
    (darterfly/journal:note-save)
    (darterfly/journal:note-form "(+ 2 2)")
    (is (= 1 (darterfly/journal:trim)))
    (is (equal '("(+ 2 2)") (mapcar #'fifth (darterfly/journal:forms-since-save))))))

(test a-runtime-without-the-heap-check-does-not-block-saving
  (is (null (darterfly/install:heap-errors)) "the host runtime has no check, and says so with nil instead of an error"))

(test a-save-handoff-times-out-without-running-later
  (let* ((ready (sb-thread:make-semaphore :count 0))
         (release (sb-thread:make-semaphore :count 0))
         (ran nil) (accepted nil)
         (worker (sb-thread:make-thread
                  (lambda ()
                    (sb-sys:without-interrupts
                      (sb-thread:signal-semaphore ready)
                      (sb-thread:wait-on-semaphore release))))))
    (unwind-protect
         (progn
           (is-true (sb-thread:wait-on-semaphore ready :timeout 2))
           (signals error
             (darterfly/install::on-save-thread
              (lambda () (setf ran t)) :thread worker :within 0.05
              :accepted (lambda () (setf accepted t))))
           (is-false accepted)
           (sb-thread:signal-semaphore release)
           (sb-thread:join-thread worker :timeout 2)
           (is-false ran "a cancelled interrupt never starts the save later"))
      (sb-thread:signal-semaphore release)
      (sb-thread:join-thread worker :timeout 2 :default nil))))

(test a-save-handoff-confirms-its-owner
  (let* ((ready (sb-thread:make-semaphore :count 0))
         (finished (sb-thread:make-semaphore :count 0))
         (ran nil) (accepted nil)
         (worker (sb-thread:make-thread
                  (lambda () (sb-thread:signal-semaphore ready) (sleep 5)))))
    (unwind-protect
         (progn
           (sb-thread:wait-on-semaphore ready :timeout 2)
           (is-true
            (darterfly/install::on-save-thread
             (lambda ()
               (setf ran sb-thread:*current-thread*)
               (sb-thread:signal-semaphore finished))
             :thread worker :within 1
             :accepted (lambda () (setf accepted t))))
           (is-true accepted)
           (is-true (sb-thread:wait-on-semaphore finished :timeout 2))
           (is (eq worker ran)))
      (sb-thread:terminate-thread worker)
      (sb-thread:join-thread worker :timeout 2 :default nil))))

(test broken-health-probes-prevent-confirmation
  (is (equal '(:wifi)
             (darterfly/start::unhealthy
              '((:log :ok) (:disk :ok) (:wifi :fail :error "broken probe")) nil)))
  (is (null (darterfly/start::unhealthy
             '((:log :ok) (:disk :ok) (:wifi :fail :ssid nil))
             '((:wifi :ok)))))
  (is (member :display (darterfly/start::unhealthy
                       '((:log :ok) (:disk :ok)) '((:display :ok)))))
  (is (member :disk (darterfly/start::unhealthy '((:log :ok)) nil))))

(test a-save-preparation-failure-does-not-restart-running-services
  (let* ((dir (merge-pathnames "save-preparation/" (scratch)))
         (blocker (merge-pathnames "not-a-directory" dir))
         (darterfly/install::*pending-generation* (namestring (merge-pathnames "not-a-directory/pending" dir)))
         (darterfly/journal:*journal* (namestring (merge-pathnames "journal" dir)))
         (darterfly/install::*deployment* nil)
         (darterfly/install::*saving* t)
         (darterfly/bsd::*suspended* nil)
         (darterfly/bsd::*threads-to-resume* nil)
         (hooks 0))
    (ensure-directories-exist blocker)
    (with-open-file (s blocker :direction :output :if-exists :supersede) (write-line "block" s))
    (sb-int:encapsulate 'darterfly/power:flush-disks 'save-preparation-test
                        (lambda (original &rest args) (declare (ignore original args)) t))
    (sb-int:encapsulate 'sb-impl::call-hooks 'save-preparation-test
                        (lambda (original &rest args) (declare (ignore original args)) (incf hooks)))
    (unwind-protect
         (progn
           (is (null (darterfly/install::begin-save nil nil nil nil nil)))
           (is-false darterfly/install::*saving*)
           (is (= 0 hooks))
           (is (null darterfly/bsd::*suspended*)))
      (sb-int:unencapsulate 'sb-impl::call-hooks 'save-preparation-test)
      (sb-int:unencapsulate 'darterfly/power:flush-disks 'save-preparation-test))))

(test a-second-deployment-cannot-take-the-first-ones-record
  (let ((darterfly/install::*deployment* "first")
        (darterfly/install::*saving* nil))
    (signals error (darterfly/install::claim-deployment "second"))
    (is (equal "first" darterfly/install::*deployment*))
    (darterfly/install::finish-deployment "older" :healthy "gen-old")
    (is (equal "first" darterfly/install::*deployment*))))

(defun deployment-input (path content &key (end t))
  (let ((wire (merge-pathnames "deployment-wire" (scratch))))
    (with-open-file (s wire :direction :output :element-type '(unsigned-byte 8) :if-exists :supersede)
      (let ((bytes (sb-ext:string-to-octets content :external-format :utf-8)))
        (write-sequence (sb-ext:string-to-octets (format nil "file ~d 644 ~a~%" (length bytes) (subseq (namestring path) 1))) s)
        (write-sequence bytes s)
        (when end (write-sequence #(101 110 100 10) s))))
    wire))

(test a-refused-or-incomplete-transfer-keeps-live-files
  (let* ((darterfly/vfs:*root* (darterfly/vfs:make-host-root))
         (darterfly/vfs:*mounts* nil)
         (darterfly/devices::*registry-root* (make-instance 'darterfly/devices:entry))
         (darterfly/vfs::*cwd* (list (cons "" darterfly/vfs:*root*)))
         (darterfly/vfs::*files* (make-hash-table))
         (darterfly/install::*written* nil)
         (target (merge-pathnames "live-probe.lisp" (scratch)))
         (stage (namestring (merge-pathnames "incoming/" (scratch))))
         (old "(in-package #:darterfly/test) (defstruct reload-probe a b)")
         (new "(in-package #:darterfly/test) (defstruct reload-probe a b c)"))
    (with-open-file (s target :direction :output :if-exists :supersede) (write-string old s))
    (with-open-file (s (deployment-input target new) :element-type '(unsigned-byte 8))
      (is (search "deploy refused" (handler-case (darterfly/install::receive-files s stage)
                                    (error (e) (princ-to-string e))))))
    (is (equal old (uiop:read-file-string target)))
    (is (null darterfly/install::*written*))
    (with-open-file (s (deployment-input target "; safe change" :end nil) :element-type '(unsigned-byte 8))
      (is (search "end marker" (handler-case (darterfly/install::receive-files s stage)
                                 (error (e) (princ-to-string e))))))
    (is (equal old (uiop:read-file-string target)))
    (is (null darterfly/install::*written*))
    ;; A previously refused old receiver may have already written bad source.
    ;; A compatible replacement must be checked instead of that stale file.
    (with-open-file (s target :direction :output :if-exists :supersede) (write-string new s))
    (setf darterfly/install::*written* (list (namestring target)))
    (with-open-file (s (deployment-input target "; safe change") :element-type '(unsigned-byte 8))
      (is (= 1 (getf (darterfly/install::receive-files s stage) :written))))
    (is (equal "; safe change" (uiop:read-file-string target)))
    (is (member (namestring target) darterfly/install::*written* :test #'equal))))

(test a-cold-boot-does-not-reopen-a-finished-deployment
  (let ((darterfly/install::*deployments-dir* (namestring (merge-pathnames "deployment-history/" (scratch))))
        (darterfly/install::*deployment* "closed")
        (darterfly/vfs:*syncers* nil))
    (darterfly/install::note-deployment "closed" :healthy "gen-2")
    (is (null (darterfly/install::resume-deployment)))
    (is (= 1 (length (darterfly/install::deployment-record "closed"))))
    (setf darterfly/install::*deployment* "pending")
    (darterfly/install::note-deployment "pending" :installed "gen-3")
    (is (equal "pending" (darterfly/install::resume-deployment)))))

(test source-packaging-respects-ignored-artifacts-and-local-edits
  (let ((root (merge-pathnames "source-package/" (scratch))))
    (ensure-directories-exist root)
    (flet ((put (name text)
             (let ((file (merge-pathnames name root)))
               (ensure-directories-exist file)
               (with-open-file (s file :direction :output :if-exists :supersede)
                 (write-string text s)))))
      (uiop:run-program '("git" "init" "-q") :directory root)
      (put ".gitignore" "*.qcow2")
      (put "tracked.lisp" "before")
      (put "deleted.lisp" "gone")
      (uiop:run-program '("git" "add" ".gitignore" "tracked.lisp" "deleted.lisp")
                        :directory root)
      (put "tracked.lisp" "edited")
      (delete-file (merge-pathnames "deleted.lisp" root))
      (put "new.lisp" "new source")
      (put "tahoe/guest/disk.qcow2" "must not ship")
      (let* ((entries (image::source-entries root))
             (names (mapcar #'second entries)))
        (is (member "usr/src/darterfly/new.lisp" names :test #'equal))
        (is (not (member "usr/src/darterfly/deleted.lisp" names :test #'equal)))
        (is (not (find-if (lambda (name) (search "qcow2" name)) names)))
        (is (equalp (image::text "edited")
                    (third (find "usr/src/darterfly/tracked.lisp" entries
                                 :key #'second :test #'equal))))))))
