(in-package #:finch/test)

(def-suite boot :in all)
(in-suite boot)

(defun screen-until (predicate &optional (seconds 30))
  (loop :with deadline := (+ (get-internal-real-time) (* seconds internal-time-units-per-second))
        :for screen := (image:screendump)
        :until (or (funcall predicate screen) (> (get-internal-real-time) deadline))
        :do (sleep 0.1)
        :finally (return screen)))

(defun dark-pixels (screen x0 y0 x1 y1 level)
  (loop :for y :from y0 :below y1
        :sum (loop :for x :from x0 :below x1
                   :count (< (ldb (byte 8 0) (image:pixel screen x y)) level))))

(test boot-efi-starts-the-kernel
  (let ((c (image:bare-console :boot-args "halt" :root nil)))
    (unwind-protect
         (progn
           (is (image:expect c "finch boot.efi"))
           (is (search "boot.efi: Core " (image:expect c "rsdp 0x")) "boot.efi loads the core beside the kernel")
           (is (image:expect c "boot-args \"halt -- --core /System/Library/Kernels/finch.core\""))
           (is (image:expect c "finch Kernel Version"))
           (is (image:expect c "boot_args: Revision 1 Version 2 efiMode 64"))
           (is (search "kslide 0x" (image:expect c "memory:")))
           (is (search "MB usable" (image:expect c "video: 1280x800x32")))
           (is (image:expect c (format nil "~%halt"))))
      (image:finish c 5))))

(test boot-efi-falls-back-to-the-previous-generation
  (let ((esp (image:esp :boot-args "halt")))
    (flet ((put (path text)
             (let ((at (merge-pathnames path esp)))
               (ensure-directories-exist at)
               (with-open-file (s at :direction :output :if-exists :supersede) (write-line text s)))))
      (put "EFI/finch/gen-2/kernel" "not a kernel")
      (put "EFI/finch/current" "gen-2")
      (put "EFI/finch/previous" "gen-1"))
    (let ((c (image::console :args (image::bare-qemu esp))))
      (unwind-protect
           (progn
             (is (image:expect c "boot.efi: generation gen-2 will not boot"))
             (is (image:expect c "boot.efi: generation gen-1"))
             (is (image:expect c (format nil "~%halt"))))
        (image:finish c 5)))))

(test the-kernel-owns-the-machine
  (let ((c (image:bare-console :boot-args "trap halt" :root nil)))
    (unwind-protect
         (progn
           (is (image:expect c "mp_desc: gdt, idt and ktss loaded"))
           (is (image:expect c "pmap: physmap"))
           (let ((panic (image:expect c "Error code")))
             (is (search "panic(cpu 0 caller 0x" panic))
             (is (search "Kernel trap at 0x" panic))
             (is (search "type 3=breakpoint" panic))
             (is (search "CS:  0x0000000000000008, SS:  0x0000000000000010" panic))))
      (image:finish c 5))))

(test the-kernel-has-memory
  (let ((c (image:bare-console :boot-args "vmtest halt" :root nil)))
    (unwind-protect
         (progn
           (is (search "at 0xffff800000000000" (image:expect c "kernel at 0xffffffff80000000")))
           (is (image:expect c "vmtest: 512 demand-zero pages, 512 read back"))
           (is (image:expect c "vmtest: kalloc reuses freed blocks")))
      (image:finish c 5))))

(test sbcl-runs-on-finch
  (let ((c (image:bare-console)))
    (flet ((ask (form) (image:send c form) (image:expect c (format nil "~%* ") :timeout 60)))
      (unwind-protect
           (progn
             (is (image:expect c "load_init_program: sbcl"))
             (is (image:expect c "* " :timeout 60))
             (is (search "\"2.6.4.finch\"" (ask "(lisp-implementation-version)")))
             (is (search "200000000" (ask "(let ((n 0)) (dotimes (i 200) (incf n (length (make-array 1000000)))) n)")))
             (ask "(gc :full t)")
             (is (search "3000000" (ask "(length (loop repeat 3000000 collect (cons 1 2)))")))
             (image:send c "(car 1)")
             (is (search "is not of type" (image:expect c "0] " :timeout 30)))
             (image:send c ":abort")
             (image:expect c "* " :timeout 30)
             (ask "(defun fib (n) (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2)))))")
             (is (search "832040" (ask "(fib 30)")))
             (is (search "T" (ask "(> (get-universal-time) 3960000000)")))
             (ask "(finch/io:test-pattern (finch/io:open-framebuffer))")
             (let ((screen (screen-until (lambda (s) (= #xff202020 (image:pixel s 1000 700))) 10)))
               (is (= #xffff0000 (image:pixel screen 10 10)))
               (is (= #xff00ff00 (image:pixel screen 1000 10)))
               (is (= #xff0000ff (image:pixel screen 10 700)))
               (is (= #xff202020 (image:pixel screen 1000 700))))
             (image:send c "(sb-ext:exit :code 7)")
             (is (image:expect c "exit(7)" :timeout 30)))
        (image:finish c 5)))))

(test interrupts-reach-lisp
  (let ((c (image:bare-console)))
    (flet ((ask (form) (image:send c form) (image:expect c (format nil "~%* ") :timeout 30)))
      (unwind-protect
           (progn
             (is (search "lapic: timer" (image:expect c "load_init_program: sbcl")))
             (image:expect c "* " :timeout 60)
             (let ((slept (ask "(let ((s (get-internal-real-time))) (sleep 0.5) (- (get-internal-real-time) s))")))
               (is (<= 500000 (parse-integer slept :junk-allowed t :start (position-if #'digit-char-p slept)) 600000)))
             (ask "(defvar *n* 0)")
             (ask "(progn (sb-ext:schedule-timer (sb-ext:make-timer (lambda () (incf *n*))) 0.05 :repeat-interval 0.05) :scheduled)")
             (let ((n (ask "(progn (sleep 1) *n*)")))
               (is (<= 18 (parse-integer n :junk-allowed t :start (position-if #'digit-char-p n)) 22) "~s" n))
             (image:send c "(loop)")
             (sleep 0.5)
             (image:send-char c (code-char 3))
             (is (search "INTERACTIVE-INTERRUPT" (image:expect c "0] " :timeout 30)))
             (image:send c ":abort")
             (image:expect c "* " :timeout 30)
             (is (search "3" (ask "(+ 1 2)"))))
        (image:finish c 5)))))

(test threads-on-finch
  (let ((c (image:bare-console)))
    (flet ((ask (form) (image:send c form) (image:expect c (format nil "~%* ") :timeout 60)))
      (unwind-protect
           (progn
             (image:expect c "* " :timeout 60)
             (is (search ":SB-THREAD" (ask "(find :sb-thread *features*)")))
             (is (search "3" (ask "(sb-thread:join-thread (sb-thread:make-thread (lambda () (+ 1 2))))")))
             (is (search "(0 1000000 2000000 3000000)"
                         (ask "(let ((ts (loop for i below 4 collect (let ((i i)) (sb-thread:make-thread (lambda () (loop repeat 1000000 sum i))))))) (mapcar #'sb-thread:join-thread ts))")))
             (is (search "80000"
                         (ask "(let ((m (sb-thread:make-mutex)) (n 0)) (mapc #'sb-thread:join-thread (loop repeat 4 collect (sb-thread:make-thread (lambda () (dotimes (i 20000) (sb-thread:with-mutex (m) (incf n))))))) n)")))
             (is (search "(30000000 30000000 30000000)"
                         (ask "(let ((ts (loop repeat 3 collect (sb-thread:make-thread (lambda () (let ((n 0)) (dotimes (i 300) (incf n (length (make-array 100000)))) n)))))) (mapcar #'sb-thread:join-thread ts))"))))
        (image:finish c 5)))))

(test smp-on-finch
  (let ((c (image:bare-console :boot-args "cpus=1 halt" :root nil)))
    (unwind-protect (is (image:expect c "mp: 1 cpu"))
      (image:finish c 5)))
  (let ((c (image:bare-console)))
    (flet ((ask (form) (image:send c form) (image:expect c (format nil "~%* ") :timeout 120)))
      (unwind-protect
           (progn
             (is (image:expect c "mp: 4 cpus"))
             (image:expect c "* " :timeout 60)
             (ask "(defun cpu () (sb-alien:alien-funcall (sb-alien:extern-alien \"_os_cpu_number\" (function sb-alien:unsigned))))")
             (is (search "(0 1 2 3)"
                         (ask "(let ((ts (loop repeat 4 collect (sb-thread:make-thread (lambda () (let ((seen nil)) (dotimes (i 200000) (pushnew (cpu) seen)) seen)))))) (sort (remove-duplicates (mapcan #'sb-thread:join-thread ts)) #'<))")))
             (ask "(defun work () (let ((n 0)) (declare (fixnum n)) (dotimes (i 1000000000) (setf n (logand (+ n i) #xffffff))) n))")
             (ask "(defun timed (k) (let ((t0 (get-internal-real-time))) (mapc #'sb-thread:join-thread (loop repeat k collect (sb-thread:make-thread #'work))) (- (get-internal-real-time) t0)))")
             (is (search "T" (ask "(let ((one (timed 1)) (four (timed 4))) (< four (* 2 one)))")))
             (is (search "(30000000 30000000 30000000 30000000)"
                         (ask "(let ((ts (loop repeat 4 collect (sb-thread:make-thread (lambda () (let ((n 0)) (dotimes (i 300) (incf n (length (make-array 100000)))) n)))))) (mapcar #'sb-thread:join-thread ts))")))
             (is (search "T"
                         (ask "(dotimes (k 5 t) (let ((ts (loop repeat 8 collect (sb-thread:make-thread (lambda () (let ((h (make-hash-table))) (dotimes (r 40) (dotimes (i 20000) (setf (gethash i h) (make-list 10)))) (hash-table-count h))))))) (assert (every (lambda (n) (= n 20000)) (mapcar #'sb-thread:join-thread ts)))))")))
             (is (search ":OK"
                         (ask "(let ((m (sb-thread:make-mutex)) (q (sb-thread:make-waitqueue)) (turn 0)) (mapc #'sb-thread:join-thread (loop for i below 4 collect (let ((i i)) (sb-thread:make-thread (lambda () (dotimes (r 5000) (sb-thread:with-mutex (m) (loop until (= turn i) do (sb-thread:condition-wait q m)) (setf turn (mod (1+ turn) 4)) (sb-thread:condition-broadcast q)))))))) :ok)")))
             (is (search "T" (ask "(let ((ids (mapcar #'sb-thread:join-thread (loop repeat 4 collect (sb-thread:make-thread (lambda () (sb-thread::thread-os-tid sb-thread:*current-thread*))))))) (= 4 (length (remove-duplicates ids))))")))
             (is (search ":OK"
                         (ask "(let* ((sem (sb-thread:make-semaphore)) (ts (loop repeat 4 collect (sb-thread:make-thread (lambda () (dotimes (i 5000) (sb-thread:signal-semaphore sem))))))) (dotimes (i 20000) (sb-thread:wait-on-semaphore sem)) (mapc #'sb-thread:join-thread ts) :ok)"))))
        (image:finish c 5)))))

(defun pattern-disk (name sectors)
  (let ((path (merge-pathnames name (finch-file "build/"))))
    (with-open-file (s path :direction :output :element-type '(unsigned-byte 8) :if-exists :supersede)
      (dotimes (i sectors)
        (let ((sector (make-array 512 :element-type '(unsigned-byte 8) :initial-element 0)))
          (replace sector (map 'vector #'char-code (format nil "finch sector ~d" i)))
          (write-sequence sector s))))
    path))

(defun disk-sector (path n)
  (with-open-file (s path :element-type '(unsigned-byte 8))
    (file-position s (* n 512))
    (let ((sector (make-array 512 :element-type '(unsigned-byte 8))))
      (read-sequence sector s)
      (map 'string #'code-char (subseq sector 0 (or (position 0 sector) 512))))))

(test iokit-on-finch
  (let* ((disk (pattern-disk "iokit-disk.img" 2048))
         (c (image:bare-console :disks (list disk))))
    (flet ((ask (form) (image:send c form) (image:expect c (format nil "~%* ") :timeout 60)))
      (unwind-protect
           (progn
             (image:expect c "* " :timeout 60)
             (let ((tree (ask "(progn (iokit:start-iokit) (iokit:ioreg))")))
               (is (search "+-o PCI0  <class IOACPIPlatformDevice>" tree))
               (is (search "+-o pci1af4,1001@4  <class IOPCIDevice>" tree))
               (is (search "| +-o AppleVirtIOPCITransport  <class AppleVirtIOPCITransport>" tree))
               (is (search "+-o AppleVirtIOBlockStorageDevice  <class AppleVirtIOBlockStorageDevice>" tree)))
             (ask "(defvar *b* (find 2048 (iokit:find-entries 'iokit:apple-virtio-block-storage-device) :key #'iokit:block-count))")
             (is (search "\"finch sector 5\"" (ask "(map 'string #'code-char (subseq (iokit:read-blocks *b* 5 1) 0 14))")))
             (is (search "\"finch sector 1099\""
                         (ask "(map 'string #'code-char (subseq (iokit:read-blocks *b* 1000 100) (* 99 512) (+ (* 99 512) 17)))")))
             (ask "(iokit:write-blocks *b* 7 (let ((v (make-array 512 :element-type '(unsigned-byte 8) :initial-element 0))) (replace v (map 'vector #'char-code \"written by finch\")) v))")
             (is (search "\"written by finch\"" (ask "(map 'string #'code-char (subseq (iokit:read-blocks *b* 7 1) 0 16))")))
             (is (search "(T T T)" (ask "(mapcar (lambda (s) (and (<= #x30 (iokit:interrupt-vector s) #x3f) t)) (list *b* (first (iokit:find-entries 'iokit:apple-virtio-input)) (first (iokit:find-entries 'iokit:apple-virtio-network))))")))
             (image:send c "(sb-ext:exit)")
             (image:expect c "exit(0)" :timeout 30))
        (image:finish c 5))
      (is (equal "written by finch" (disk-sector disk 7)))
      (is (equal "finch sector 8" (disk-sector disk 8))))))

(defun gunzip-fixture (name to)
  (let ((path (merge-pathnames to (finch-file "build/"))))
    (with-open-file (in (finch-file (format nil "tests/~a" name)) :element-type '(unsigned-byte 8))
      (with-open-file (out path :direction :output :element-type '(unsigned-byte 8) :if-exists :supersede)
        (chipz:decompress out 'chipz:gzip in)))
    path))

(defparameter *media-keys*
  '("Content" "Content Hint" "Whole" "Leaf" "Writable" "Preferred Block Size" "Size" "Base" "UUID" "Partition ID" "BSD Name"
    "Logical Block Size" "Physical Block Size" "FullName" "RoleValue" "CaseSensitive" "FormattedBy" "IncompatibleFeatures"))

(defun ioreg-value (text)
  (cond ((string= text "Yes") t)
        ((string= text "No") nil)
        ((char= (char text 0) #\") (subseq text 1 (1- (length text))))
        (t (parse-integer text))))

(defun ioreg-media (file)
  (let ((entries nil) (current nil))
    (dolist (line (uiop:read-file-lines file))
      (let ((o (search "+-o " line)))
        (cond (o (let* ((head (subseq line (+ o 4) (search "  <class " line)))
                        (at (position #\@ head :from-end t)))
                   (setf current (and (some (lambda (c) (search c line)) '("<class IOMedia," "<class AppleAPFSMedia," "<class AppleAPFSVolume,"))
                                      (list (if at (subseq head 0 at) head) (and at (subseq head (1+ at))) nil)))
                   (when current (push current entries))))
              (current
               (let ((q (search "\" = " line)))
                 (when q
                   (let ((key (subseq line (1+ (position #\" line)) q)))
                     (when (member key *media-keys* :test #'string=)
                       (push (cons key (ioreg-value (subseq line (+ q 4)))) (third current))))))))))
    (nreverse entries)))

(defun bsd-suffix (name) (subseq name (or (position #\s name :start 4) (length name))))

(test media-matches-tahoe
  (let* ((disk (gunzip-fixture "apfs-disk.img.gz" "apfs-disk.img"))
         (want (ioreg-media (finch-file "tests/media.txt")))
         (c (image:bare-console :disks (list disk))))
    (flet ((ask (form) (image:send c form) (image:expect c (format nil "~%* ") :timeout 60)))
      (unwind-protect
           (progn
             (image:expect c "* " :timeout 60)
             (ask "(iokit:start-iokit)")
             (let* ((answer (ask (format nil "(let ((whole (find ~d (iokit:find-entries 'iokit:io-media) :key #'iokit:media-size))) (format t \"~~&@@~~s@@~~%\" (mapcar (lambda (m) (list (iokit:entry-name m) (iokit:entry-location m) (loop for k in '~s collect (cons k (iokit:get-property m k))))) (iokit:find-entries 'iokit:io-media whole))))"
                                         (cdr (assoc "Size" (third (first want)) :test #'string=)) *media-keys*)))
                    (got (read-from-string (subseq answer (+ 2 (search "@@" answer)) (search "@@" answer :from-end t)))))
               (is (= (length want) (length got)))
               (loop for (wname wloc wprops) in want
                     for (gname gloc gprops) in got
                     for whole = (cdr (assoc "Whole" wprops :test #'string=))
                     do (unless whole
                          (is (equal wname gname))
                          (is (equal wloc gloc)))
                        (loop for (key . value) in wprops
                              for mine = (cdr (assoc key gprops :test #'string=))
                              do (cond ((string= key "BSD Name") (is (equal (bsd-suffix value) (bsd-suffix mine))))
                                       (t (is (equal value mine) "~a ~a: Tahoe ~s, finch ~s" wname key value mine))))))
             (is (search (let ((line (find "UUID" (uiop:read-file-lines (finch-file "tests/media.txt"))
                                           :test (lambda (k l) (and (search k l) (search "|   \"UUID\"" l))))))
                           (subseq line (- (length line) 37) (1- (length line))))
                         (ask "(iokit:get-property (first (iokit:find-entries 'iokit:io-guid-partition-scheme)) \"UUID\")"))))
        (image:finish c 5)))))

(test apfs-on-finch
  (let* ((disk (gunzip-fixture "apfs-disk.img.gz" "apfs-boot.img"))
         (files (mapcar (lambda (l) (uiop:split-string l :separator "|")) (uiop:read-file-lines (finch-file "tests/apfs-files.txt"))))
         (c (image:bare-console :disks (list disk))))
    (flet ((ask (form) (image:send c form) (image:expect c (format nil "~%* ") :timeout 120)))
      (unwind-protect
           (progn
             (image:expect c "* " :timeout 60)
             (ask "(iokit:start-iokit)")
             (ask "(defvar *v* (find \"finch\" (mapcar #'finch/apfs::apfs-volume (iokit:find-entries 'finch/apfs::apple-apfs-volume)) :key #'finch/apfs:volume-name :test #'equal))")
             (is (search "\"finch\"" (ask "(finch/apfs:volume-name *v*)")))
             (is (search "\"hello from tahoe" (ask "(map 'string #'code-char (finch/apfs:read-file *v* (finch/apfs:lookup *v* \"/hello.txt\")))")))
             (is (search "\"hello.txt\"" (ask "(finch/apfs:readlink *v* (finch/apfs:lookup *v* \"/link\"))")))
             (is (search "300" (ask "(length (finch/apfs:directory-entries *v* (finch/apfs:lookup *v* \"/many\")))")))
             (is (search (format nil "~s" (car (last (find "./big.txt" files :key #'first :test #'string=))))
                         (ask "(string-downcase (format nil \"~{~2,'0x~}\" (coerce (sb-md5:md5sum-sequence (finch/apfs:read-file *v* (finch/apfs:lookup *v* \"/big.txt\"))) 'list)))"))))
        (image:finish c 5)))))

(test apfs-mounts-on-finch
  (let* ((disk (gunzip-fixture "apfs-disk.img.gz" "apfs-mount.img"))
         (c (image:bare-console :disks (list disk))))
    (flet ((ask (form) (image:send c form) (image:expect c (format nil "~%* ") :timeout 120)))
      (unwind-protect
           (progn
             (image:expect c "* " :timeout 60)
             (ask "(iokit:start-iokit)")
             (is (search "(\"/Volumes/finch\")" (ask "(finch/apfs:mount-volumes)")))
             (is (search "\"hello from tahoe\"" (ask "(with-open-file (s \"/Volumes/finch/hello.txt\") (read-line s))")))
             (is (search "300" (ask "(length (directory \"/Volumes/finch/many/*\"))")))
             (is (search "#P\"/Volumes/finch/hello.txt\"" (ask "(truename \"/Volumes/finch/link\")")))
             (is (search "(0 NIL)"
                         (ask (concatenate 'string
                                           "(let ((bad nil) (n 0)) "
                                           "(dolist (l (uiop:read-file-lines \"/finch/tests/apfs-files.txt\") (list (- 309 n) bad)) "
                                           "(destructuring-bind (path type perms size ino nlink uid gid target md5) (uiop:split-string l :separator \"|\") "
                                           "(declare (ignore type target md5)) "
                                           "(let ((st (sb-posix:lstat (concatenate 'string \"/Volumes/finch\" (subseq path 1))))) "
                                           "(if (and (= (parse-integer perms :radix 8) (logand (sb-posix:stat-mode st) #o7777)) "
                                           "(= (parse-integer size) (sb-posix:stat-size st)) (= (parse-integer ino) (sb-posix:stat-ino st)) "
                                           "(= (parse-integer nlink) (sb-posix:stat-nlink st)) (= (parse-integer uid) (sb-posix:stat-uid st)) "
                                           "(= (parse-integer gid) (sb-posix:stat-gid st))) (incf n) (push path bad))))))"))))
             (is (search "read-only file system" (ask "(handler-case (with-open-file (s \"/Volumes/finch/new.txt\" :direction :output) (write-line \"x\" s)) (error (e) (string-downcase (princ-to-string e))))"))))
        (image:finish c 5)))))

(test apfs-writes-on-finch
  (let* ((disk (merge-pathnames "apfs-write-boot.img" (finch-file "build/")))
         (c (progn (uiop:copy-file (newfs-image) disk) (image:bare-console :disks (list disk)))))
    (flet ((ask (form) (image:send c form) (image:expect c (format nil "~%* ") :timeout 120)))
      (unwind-protect
           (progn
             (image:expect c "* " :timeout 60)
             (ask "(iokit:start-iokit)")
             (is (search "(\"/Volumes/finch\")" (ask "(finch/apfs:mount-volumes :writable t)")))
             (ask "(with-open-file (s \"/Volumes/finch/from-finch.txt\" :direction :output) (write-line \"written on bare finch\" s))")
             (ask "(ensure-directories-exist \"/Volumes/finch/made/by/finch/\")")
             (ask "(with-open-file (s \"/Volumes/finch/made/by/finch/lines.txt\" :direction :output) (dotimes (i 3000) (format s \"line ~d~%\" i)))")
             (ask "(delete-file \"/Volumes/finch/many/f7\")")
             (ask "(rename-file \"/Volumes/finch/hello.txt\" \"/Volumes/finch/made/hello.txt\")")
             (is (search "\"written on bare finch\"" (ask "(with-open-file (s \"/Volumes/finch/from-finch.txt\") (read-line s))")))
             (image:send c "(sb-ext:exit)")
             (image:expect c "exit(0)" :timeout 30))
        (image:finish c 5))
      (let* ((v (first (apfs:container-volumes (apfs:open-container (apfs:file-device disk)))))
             (read (lambda (path) (map 'string #'code-char (apfs:read-file v (apfs:lookup v path))))))
        (is (equal (format nil "written on bare finch~%") (funcall read "/from-finch.txt")))
        (is (equal (with-output-to-string (s) (dotimes (i 3000) (format s "line ~d~%" i))) (funcall read "/made/by/finch/lines.txt")))
        (is (equal (format nil "hello from finch~%") (funcall read "/made/hello.txt")))
        (is (null (apfs:lookup v "/many/f7")))
        (is (null (apfs:lookup v "/hello.txt")))
        (is (= 299 (length (apfs:directory-entries v (apfs:lookup v "/many")))))
        (is (= #o100644 (apfs:inode-mode (apfs:inode v (apfs:lookup v "/from-finch.txt")))))
        (is (= #o040755 (apfs:inode-mode (apfs:inode v (apfs:lookup v "/made/by")))))))))

(test apfs-root-on-finch
  (let* ((disk (merge-pathnames "root-keep.img" (finch-file "build/")))
         (c (progn (uiop:delete-file-if-exists disk) (image:bare-console :root disk))))
    (flet ((ask (form) (image:send c form) (image:expect c (format nil "~%* ") :timeout 120)))
      (unwind-protect
           (progn
             (image:expect c "* " :timeout 60)
             (is (search "APFS-WVNODE" (ask "(type-of (finch/vfs:namei \"/\"))")))
             (is (search "\"finch HD\"" (ask "(iokit:get-property (find \"disk2s1\" (iokit:find-entries 'finch/apfs::apple-apfs-volume) :key (lambda (e) (iokit:get-property e \"BSD Name\")) :test #'equal) \"FullName\")")))
             (is (search "334" (ask "(length (uiop:read-file-lines \"/finch/tests/ports.txt\"))")))
             (is (search "#P\"/System/Library/Kernels/kernel\"" (ask "(probe-file \"/System/Library/Kernels/kernel\")")))
             (is (search "DEV-NODE" (ask "(type-of (finch/vfs:namei \"/dev/console\"))")))
             (is (search "T" (ask "(finch/iokit::flushes (finch/iokit::media-device finch/apfs::*root-media*))"))
                 "the root disk takes flushes")
             (is (search ":LOADED" (ask "(progn (require :sb-rotate-byte) (require :sb-md5) :loaded)")) "contribs from SBCL_HOME")
             (is (search "2.5d0" (ask "(progn (load \"/usr/lib/sbcl/contrib/sb-posix.fasl\") (sb-posix:strtod \"2.5\"))"))
                 "a fasl that calls C reaches the alien linkage table")
             (is (search "(16 T)" (ask "(with-open-file (s \"/dev/urandom\" :element-type '(unsigned-byte 8)) (let ((a (make-array 16 :element-type '(unsigned-byte 8))) (b (make-array 16 :element-type '(unsigned-byte 8)))) (list (read-sequence a s) (progn (read-sequence b s) (not (equalp a b))))))"))
                 "/dev/urandom gives bytes from rdrand")
             (is (search "T" (ask "(not (null (probe-file \"/etc/ssl/certs/ca-certificates.crt\")))")) "the CA bundle is on the root")
             (is (search "\"0.1\"" (ask "(software-version)")))
             (dolist (root '("/tmp/tree/" "/Users/finch/tree/"))
               (is (search "(NIL)" (ask (format nil "(progn (dolist (f '(\"a/x\" \"a/b/y\" \"a/b/c/z\" \"a/b/w\")) (let ((p (concatenate 'string ~s f))) (ensure-directories-exist p) (with-open-file (s p :direction :output :if-exists :supersede) (write-line f s)))) (uiop:delete-directory-tree (pathname ~s) :validate t) (list (probe-file ~s)))" root root root)))
                   "a tree deletes while its directories are read, on ~a" root))
             (is (search "#P\"/Users/finch/\"" (ask "(user-homedir-pathname)")))
             (is (search "\"through a pipe\"" (ask "(multiple-value-bind (r w) (sb-posix:pipe) (let ((o (sb-sys:make-fd-stream w :output t)) (i (sb-sys:make-fd-stream r :input t))) (write-line \"through a pipe\" o) (close o) (prog1 (read-line i) (close i))))"))
                 "an fd-stream over pipe()")
             (is (search "\"hi from sh\"" (ask "(string-trim '(#\\Newline) (with-output-to-string (o) (sb-ext:run-program \"/bin/sh\" '(\"-c\" \"(princ \\\"hi from sh\\\")\") :output o)))"))
                 "run-program through posix-spawn")
             (is (search "3" (ask "(sb-ext:process-exit-code (sb-ext:run-program \"sh\" '(\"-c\" \"(finch/bsd:exit 3)\") :search t))")))
             (is (search "\"fed in\"" (ask "(with-output-to-string (o) (sb-ext:run-program \"/bin/sh\" '(\"-c\" \"(princ (read-line))\") :input (make-string-input-stream (format nil \"fed in~%\")) :output o))"))
                 "input from a lisp stream, through an unlinked file in /tmp")
             (ask "(with-open-file (s \"/Users/finch/notes.txt\" :direction :output) (write-line \"kept across boots\" s))")
             (image:send c "(sb-ext:exit)")
             (image:expect c "exit(0)" :timeout 30))
        (image:finish c 5))
      (let ((v (first (apfs:container-volumes (apfs:open-container (apfs:file-device disk))))))
        (is (equal "finch HD" (apfs:volume-name v)))
        (is (equal (format nil "kept across boots~%")
                   (map 'string #'code-char (apfs:read-file v (apfs:lookup v "/Users/finch/notes.txt")))))))))

(test desktop-on-finch
  (let ((c (image:bare-console :boot-args "launchd"))
        (image:*screen-size* '(1280 800)))
    (unwind-protect
         (progn
           (is (image:expect c "load_init_program: /sbin/launchd pid 1" :timeout 90))
           (let ((screen (screen-until (lambda (s) (and (= #xff2e5c8f (image:pixel s 5 300))
                                                        (< 200 (ldb (byte 8 16) (image:pixel s 300 12)))
                                                        (< 100 (dark-pixels s 620 724 660 764 90))))
                                       60)))
             (is (= #xff2e5c8f (image:pixel screen 5 300)) "desktop ~x" (image:pixel screen 5 300))
             (is (< 200 (ldb (byte 8 16) (image:pixel screen 1270 12))) "menu bar to the right edge ~x" (image:pixel screen 1270 12))
             (is (< 100 (dark-pixels screen 620 724 660 764 90)) "terminal's icon in the dock"))
           (image:pointer 639 744)
           (image:pointer 639 744 t)
           (image:pointer 639 744 nil)
           (let ((screen (screen-until (lambda (s) (= #xffffffff (image:pixel s 500 300))) 30)))
             (is (= #xffffffff (image:pixel screen 500 300)) "terminal's content ~x" (image:pixel screen 500 300)))
           (let ((before (dark-pixels (image:screendump) 172 160 300 200 100)))
             (image:send-keys "(+ 1 2)
")
             (is (< before (dark-pixels (screen-until (lambda (s) (< before (dark-pixels s 172 160 300 200 100))) 30)
                                        172 160 300 200 100))
                 "the answer appears")))
      (image:finish c 5))))

(defun free-udp-port ()
  (let ((s (make-instance 'sb-bsd-sockets:inet-socket :type :datagram :protocol :udp)))
    (unwind-protect (progn (sb-bsd-sockets:socket-bind s #(127 0 0 1) 0)
                           (nth-value 1 (sb-bsd-sockets:socket-name s)))
      (sb-bsd-sockets:socket-close s))))

(defun host-listener ()
  (let ((server (make-instance 'sb-bsd-sockets:inet-socket :type :stream :protocol :tcp)))
    (setf (sb-bsd-sockets:sockopt-reuse-address server) t)
    (sb-bsd-sockets:socket-bind server #(127 0 0 1) 0)
    (sb-bsd-sockets:socket-listen server 5)
    (values server (nth-value 1 (sb-bsd-sockets:socket-name server)))))

(test network-on-finch
  (let* ((udp (free-udp-port))
         (tcp (free-udp-port))
         (c (image:bare-console :forwards (list (list :udp udp 7) (list :tcp tcp 7)))))
    (flet ((ask (form) (image:send c form) (image:expect c (format nil "~%* ") :timeout 60)))
      (unwind-protect
           (progn
             (image:expect c "* " :timeout 90)
             (is (search "\"10.0.2.15\"" (ask "(progn (finch/net:start-network) (finch/net:udp-echo 7) (finch/net:tcp-echo 7) (finch/net:address-string (finch/net::interface-ip finch/net:*interface*)))")))
             (is (search "(\"10.0.2.2\" (\"10.0.2.3\") 24)" (ask "(let ((i finch/net:*interface*)) (list (finch/net:address-string (finch/net::interface-gateway i)) (mapcar #'finch/net:address-string (finch/net::interface-dns i)) (finch/net::interface-prefix i)))"))
                 "dhcp gives the gateway, the name server and the mask")
             (when (ignore-errors (sb-bsd-sockets:get-host-by-name "example.com"))
               (is (search "(\"" (ask "(finch/net:resolve-name \"example.com\")")) "finch resolves a name through the dhcp name server"))
             (is (search "\"en0\"" (ask "(iokit:get-property (first (iokit:find-entries 'iokit:io-ethernet-interface)) \"BSD Name\")")))
             (is (not (search "NIL" (ask "(finch/net:ping \"10.0.2.2\")"))) "the gateway answers a ping")
             (let ((s (make-instance 'sb-bsd-sockets:inet-socket :type :datagram :protocol :udp))
                   (buf (make-array 100 :element-type '(unsigned-byte 8))))
               (unwind-protect
                    (progn
                      (sb-bsd-sockets:socket-connect s #(127 0 0 1) udp)
                      (sb-bsd-sockets:socket-send s (sb-ext:string-to-octets "hello finch over udp") nil)
                      (is (equal "hello finch over udp"
                                 (handler-case (sb-sys:with-deadline (:seconds 10)
                                                 (multiple-value-bind (b n) (sb-bsd-sockets:socket-receive s buf nil)
                                                   (map 'string #'code-char (subseq b 0 n))))
                                   (error (e) (princ-to-string e))))))
                 (sb-bsd-sockets:socket-close s)))
             (let ((s (make-instance 'sb-bsd-sockets:inet-socket :type :stream :protocol :tcp))
                   (payload (with-output-to-string (o) (dotimes (i 1000) (format o "line ~4,'0d~%" i)))))
               (unwind-protect
                    (progn
                      (sb-bsd-sockets:socket-connect s #(127 0 0 1) tcp)
                      (let ((stream (sb-bsd-sockets:socket-make-stream s :input t :output t :element-type 'character :buffering :full))
                            (got (make-string (length payload))))
                        (write-string payload stream)
                        (finish-output stream)
                        (handler-case (sb-sys:with-deadline (:seconds 15) (read-sequence got stream)) (error () nil))
                        (is (string= payload got) "10000 bytes through finch's tcp echo")))
                 (sb-bsd-sockets:socket-close s)))
             (multiple-value-bind (server port) (host-listener)
               (unwind-protect
                    (let ((acceptor (sb-thread:make-thread
                                     (lambda ()
                                       (handler-case
                                           (sb-sys:with-deadline (:seconds 20)
                                             (let* ((conn (sb-bsd-sockets:socket-accept server))
                                                    (st (sb-bsd-sockets:socket-make-stream conn :input t :output t :element-type 'character)))
                                               (prog1 (read-line st)
                                                 (write-line "hello finch, from the host" st)
                                                 (finish-output st)
                                                 (sb-bsd-sockets:socket-close conn))))
                                         (error (e) (princ-to-string e)))))))
                      (is (search "hello finch, from the host"
                                  (ask (format nil "(let ((c (finch/net:tcp-connect \"10.0.2.2\" ~d))) (finch/net:tcp-send c (sb-ext:string-to-octets (format nil \"hello host, from finch~~%\"))) (prog1 (map 'string #'code-char (finch/net:tcp-receive c :timeout 5)) (finch/net:tcp-close c)))" port))))
                      (is (equal "hello host, from finch" (sb-thread:join-thread acceptor :default nil :timeout 20))))
                 (sb-bsd-sockets:socket-close server))))
        (image:finish c 5)))))

(defun tcp-exchange (port line)
  (let ((s (make-instance 'sb-bsd-sockets:inet-socket :type :stream :protocol :tcp)))
    (unwind-protect
         (handler-case
             (sb-sys:with-deadline (:seconds 15)
               (sb-bsd-sockets:socket-connect s #(127 0 0 1) port)
               (let ((stream (sb-bsd-sockets:socket-make-stream s :input t :output t :element-type 'character)))
                 (write-line line stream)
                 (finish-output stream)
                 (read-line stream)))
           (error (e) (princ-to-string e)))
      (sb-bsd-sockets:socket-close s))))

(test ip6-on-finch
  (let* ((server (make-instance 'sb-bsd-sockets:inet6-socket :type :stream :protocol :tcp))
         (port (progn (setf (sb-bsd-sockets:sockopt-reuse-address server) t)
                      (sb-bsd-sockets:socket-bind server (sb-bsd-sockets:make-inet6-address "::1") 0)
                      (sb-bsd-sockets:socket-listen server 5)
                      (nth-value 1 (sb-bsd-sockets:socket-name server))))
         (c (image:bare-console)))
    (flet ((ask (form) (image:send c form) (image:expect c (format nil "~%* ") :timeout 60)))
      (unwind-protect
           (progn
             (image:expect c "* " :timeout 90)
             (ask "(progn (finch/net:start-network) :up)")
             (is (search "((\"fe80::5054:ff:fe12:3456\" \"fec0::5054:ff:fe12:3456\") \"fe80::2\")"
                         (ask "(let ((i finch/net:*interface*)) (list (mapcar #'finch/net:address-string (finch/net::interface-ip6 i)) (finch/net:address-string (finch/net::interface-router6 i))))"))
                 "a router advertisement gives the prefix and the router")
             (is (not (search "NIL" (ask "(finch/net:ping \"fec0::2\")"))) "the router answers an ICMPv6 echo")
             (let ((acceptor (sb-thread:make-thread
                              (lambda ()
                                (let* ((conn (sb-bsd-sockets:socket-accept server))
                                       (st (sb-bsd-sockets:socket-make-stream conn :input t :output t :element-type 'character)))
                                  (prog1 (read-line st) (write-line "hello finch, over ipv6" st) (finish-output st)
                                    (sb-bsd-sockets:socket-close conn)))))))
               (is (search "hello finch, over ipv6"
                           (ask (format nil "(let ((c (finch/net:tcp-connect \"fec0::2\" ~d))) (finch/net:tcp-send c (sb-ext:string-to-octets (format nil \"hello host~~%\"))) (prog1 (map 'string #'code-char (finch/net:tcp-receive c :timeout 5)) (finch/net:tcp-close c)))" port))))
               (is (equal "hello host" (sb-thread:join-thread acceptor :timeout 10 :default nil)) "tcp over ipv6 to the host"))
             (when (ignore-errors (sb-bsd-sockets:get-host-by-name "example.com"))
               (is (search ":" (ask "(finch/net:resolve-name \"example.com\" :type :aaaa)")) "an AAAA lookup")))
        (sb-bsd-sockets:socket-close server)
        (image:finish c 5)))))

(test sockets-on-finch
  (let* ((tcp (free-udp-port))
         (c (image:bare-console :forwards (list (list :tcp tcp 8)))))
    (flet ((ask (form) (image:send c form) (image:expect c (format nil "~%* ") :timeout 60)))
      (unwind-protect
           (progn
             (image:expect c "* " :timeout 90)
             (ask "(finch/net:start-network)")
             (is (search ":LISTENING" (ask "(let ((s (finch/bsd:socket finch/bsd:+af-inet+ finch/bsd:+sock-stream+))) (finch/bsd:bind s \"0.0.0.0\" 8) (finch/bsd:listen s) (sb-thread:make-thread (lambda () (loop (let ((c (finch/bsd:accept s))) (loop for d = (finch/bsd:recv c 4096) while (plusp (length d)) do (finch/bsd:send c d)) (finch/bsd:close c)))) :name \"bsd echo\") :listening)")))
             (is (equal "through accept, recv and send" (tcp-exchange tcp "through accept, recv and send")))
             (is (equal "a second connection" (tcp-exchange tcp "a second connection")))
             (multiple-value-bind (server port) (host-listener)
               (unwind-protect
                    (let ((acceptor (sb-thread:make-thread
                                     (lambda ()
                                       (handler-case
                                           (sb-sys:with-deadline (:seconds 20)
                                             (let* ((conn (sb-bsd-sockets:socket-accept server))
                                                    (st (sb-bsd-sockets:socket-make-stream conn :input t :output t :element-type 'character)))
                                               (prog1 (read-line st)
                                                 (write-line "hello finch/bsd" st)
                                                 (finish-output st)
                                                 (sb-bsd-sockets:socket-close conn))))
                                         (error (e) (princ-to-string e)))))))
                      (is (search "hello finch/bsd"
                                  (ask (format nil "(let ((s (finch/bsd:socket finch/bsd:+af-inet+ finch/bsd:+sock-stream+))) (finch/bsd:connect s \"10.0.2.2\" ~d) (finch/bsd:send s (sb-ext:string-to-octets (format nil \"hello host, from connect~~%\"))) (prog1 (map 'string #'code-char (finch/bsd:recv s 100)) (finch/bsd:close s)))" port))))
                      (is (equal "hello host, from connect" (sb-thread:join-thread acceptor :default nil :timeout 20))))
                 (sb-bsd-sockets:socket-close server)))
             (multiple-value-bind (server port) (host-listener)
               (unwind-protect
                    (let ((acceptor (sb-thread:make-thread
                                     (lambda ()
                                       (handler-case
                                           (sb-sys:with-deadline (:seconds 20)
                                             (let* ((conn (sb-bsd-sockets:socket-accept server))
                                                    (st (sb-bsd-sockets:socket-make-stream conn :input t :output t :element-type 'character)))
                                               (prog1 (read-line st)
                                                 (write-line "hello sb-bsd-sockets" st)
                                                 (finish-output st)
                                                 (sb-bsd-sockets:socket-close conn))))
                                         (error (e) (princ-to-string e)))))))
                      (is (search "\"hello sb-bsd-sockets\""
                                  (ask (format nil "(let ((s (make-instance 'sb-bsd-sockets:inet-socket :type :stream :protocol :tcp))) (sb-bsd-sockets:socket-connect s #(10 0 2 2) ~d) (let ((st (sb-bsd-sockets:socket-make-stream s :input t :output t :element-type 'character))) (write-line \"from sbcl's own sockets\" st) (finish-output st) (prog1 (read-line st) (close st))))" port)))
                          "sb-bsd-sockets over finch's tcp")
                      (is (equal "from sbcl's own sockets" (sb-thread:join-thread acceptor :default nil :timeout 20))))
                 (sb-bsd-sockets:socket-close server)))
             (let ((u (make-instance 'sb-bsd-sockets:inet-socket :type :datagram :protocol :udp))
                   (buf (make-array 100 :element-type '(unsigned-byte 8))))
               (unwind-protect
                    (progn
                      (sb-bsd-sockets:socket-bind u #(127 0 0 1) 0)
                      (let* ((port (nth-value 1 (sb-bsd-sockets:socket-name u)))
                             (replier (sb-thread:make-thread
                                       (lambda ()
                                         (handler-case
                                             (sb-sys:with-deadline (:seconds 20)
                                               (multiple-value-bind (b n address from) (sb-bsd-sockets:socket-receive u buf nil)
                                                 (sb-bsd-sockets:socket-send u (sb-ext:string-to-octets "datagram back") nil :address (list address from))
                                                 (map 'string #'code-char (subseq b 0 n))))
                                           (error (e) (princ-to-string e)))))))
                        (is (search "(\"datagram back\" \"10.0.2.2\"" (ask (format nil "(let ((s (finch/bsd:socket finch/bsd:+af-inet+ finch/bsd:+sock-dgram+))) (finch/bsd:sendto s (sb-ext:string-to-octets \"datagram out\") \"10.0.2.2\" ~d) (prog1 (multiple-value-bind (d a p) (finch/bsd:recvfrom s 100) (list (map 'string #'code-char d) a p)) (finch/bsd:close s)))" port))))
                        (is (equal "datagram out" (sb-thread:join-thread replier :default nil :timeout 20)))))
                 (sb-bsd-sockets:socket-close u)))
             (is (search "ECONNREFUSED" (ask "(handler-case (finch/bsd:connect (finch/bsd:socket finch/bsd:+af-inet+ finch/bsd:+sock-stream+) \"10.0.2.2\" 1) (finch/bsd:errno (e) (symbol-name (finch/bsd:errno-name e))))"))))
        (image:finish c 5)))))

(test xnu-checked-suites-pass-on-finch
  (let ((c (image:bare-console)))
    (flet ((ask (form) (image:send c form) (image:expect c (format nil "~%* ") :timeout 300)))
      (unwind-protect
           (progn
             (image:expect c "* " :timeout 60)
             (is (search "334" (ask "(length (uiop:read-file-lines \"/finch/tests/ports.txt\"))")))
             (is (search "(T T)"
                         (ask "(list (fiveam:results-status (fiveam:run 'finch/test::mach)) (fiveam:results-status (fiveam:run 'finch/test::bsd)))"))))
        (image:finish c 5)))))

(test session-on-finch
  (let ((c (image:bare-console :boot-args "launchd"))
        (image:*screen-size* '(1280 800)))
    (flet ((ask (form) (image:send c form) (image:expect c (format nil "~%* ") :timeout 60)))
      (unwind-protect
           (progn
             (is (image:expect c "load_init_program: /sbin/launchd pid 1" :timeout 90))
             (is (image:expect c "launchd: pid 1"))
             (is (search "3" (ask "(+ 1 2)")))
             (ask "(finch/shell:spawn \"/Applications/Hello.app/Contents/MacOS/Hello\")")
             (let ((screen (screen-until (lambda (s) (and (< 200 (ldb (byte 8 16) (image:pixel s 300 12)))
                                                          (< 100 (dark-pixels s 620 724 660 764 90))
                                                          (/= #xff2e5c8f (image:pixel s 1218 60)))))))
               (is (< 200 (ldb (byte 8 16) (image:pixel screen 300 12))) "menu bar ~x" (image:pixel screen 300 12))
               (is (< 30 (dark-pixels screen 1246 4 1276 20 120)) "the clock")
               (is (< 100 (dark-pixels screen 620 724 660 764 90)) "terminal's icon in the dock")
               (is (/= #xff2e5c8f (image:pixel screen 1218 60)) "the disk ~x" (image:pixel screen 1218 60)))
             (let ((screen (screen-until (lambda (s) (and (= #xffd9d9d9 (image:pixel s 300 140))
                                                          (= #xffededed (image:pixel s 215 520))
                                                          (< 50 (dark-pixels s 244 194 480 230 100)))))))
               (is (= #xff2e5c8f (image:pixel screen 5 300)) "desktop ~x" (image:pixel screen 5 300))
               (is (= #xffd9d9d9 (image:pixel screen 300 140)) "title ~x" (image:pixel screen 300 140))
               (is (= #xffededed (image:pixel screen 215 300)) "frame ~x" (image:pixel screen 215 300))
               (is (= #xffffffff (image:pixel screen 500 300)) "content ~x" (image:pixel screen 500 300))
               (is (< 50 (dark-pixels screen 244 194 480 230 100)) "the words")
               (is (< 5 (dark-pixels screen 470 136 560 160 120)) "the title"))
             (image:pointer 100 600)
             (let ((screen (screen-until (lambda (s) (= #xff000000 (image:pixel s 100 600))))))
               (is (= #xff000000 (image:pixel screen 100 600)) "cursor tip ~x" (image:pixel screen 100 600)))
             (image:pointer 300 145)
             (image:pointer 300 145 t)
             (image:pointer 350 245)
             (image:pointer 350 245 nil)
             (let ((screen (screen-until (lambda (s) (= #xff2e5c8f (image:pixel s 230 300))))))
               (is (= #xff2e5c8f (image:pixel screen 230 300)) "old place ~x" (image:pixel screen 230 300))
               (is (= #xffffffff (image:pixel screen 550 400)) "moved content ~x" (image:pixel screen 550 400)))
             (let ((before (dark-pixels (image:screendump) 294 294 694 334 100)))
               (image:pointer 354 370)
               (image:pointer 354 370 t)
               (image:pointer 354 370 nil)
               (is (/= before (dark-pixels (screen-until (lambda (s) (/= before (dark-pixels s 294 294 694 334 100))))
                                           294 294 694 334 100))
                   "the button changes the label"))
             (image:pointer 282 248)
             (image:pointer 282 248 t)
             (image:pointer 282 248 nil)
             (is (= #xff2e5c8f (image:pixel (screen-until (lambda (s) (= #xff2e5c8f (image:pixel s 550 400)))) 550 400))
                 "close takes the window away")
             (is (search "finch.windowserver" (ask "(finch/shell:run \"/bin/launchctl\" \"list\")")))
             (image:pointer 639 744)
             (image:pointer 639 744 t)
             (image:pointer 639 744 nil)
             (flet ((screen-text (until)
                      (loop :with deadline := (+ (get-internal-real-time) (* 30 internal-time-units-per-second))
                            :do (let ((text (ask "(progn (ignore-errors (finch/shell:cat \"/tmp/Terminal.txt\")) :done)")))
                                  (when (or (search until text) (> (get-internal-real-time) deadline))
                                    (return text)))
                                (sleep 0.1))))
               (is (search (format nil "# ~%:DONE") (screen-text (format nil "# ~%:DONE"))))
               (is (= #xffd9d9d9 (image:pixel (screen-until (lambda (s) (= #xffd9d9d9 (image:pixel s 300 110))))
                                              300 110))
                   "terminal's window")
               (image:pointer 300 110)
               (image:pointer 300 110 t)
               (image:pointer 300 110 nil)
               (image:send-keys (format nil "(+ 1 2)~%"))
               (let ((text (screen-text (format nil "(+ 1 2)~%3"))))
                 (is (search (format nil "(+ 1 2)~%3") text) "~s" text)
                 (loop :for ch :across (format nil "(length (list 'typed 'at 'full 'speed 'into 'the 'terminal 'without 'losing 'a 'single 'key 'stroke 1 2 3 4 5 6 7 8 9 10))~%")
                       :do (image:send-keys (string ch)) (sleep 0.002))
                 (let ((burst (screen-text (format nil "~%23~%"))))
                   (is (search (format nil "~%23~%") burst) "a fast burst of keys arrives whole: ~s" burst))
                 (is (< 5 (dark-pixels (screen-until (lambda (s) (< 5 (dark-pixels s 176 160 192 178 100))))
                                       176 160 192 178 100))
                     "terminal shows the answer")))
             (image:pointer 28 12)
             (image:pointer 28 12 t)
             (image:pointer 28 12 nil)
             (screen-until (lambda (s) (< 20 (dark-pixels s 10 70 120 95 100))))
             (image:pointer 60 80)
             (image:pointer 60 80 t)
             (image:pointer 60 80 nil)
             (is (= #xff2e5c8f (image:pixel (screen-until (lambda (s) (= #xff2e5c8f (image:pixel s 300 110)))) 300 110))
                 "quit takes terminal away")
             (dotimes (i 2)
               (image:pointer 1218 70)
               (image:pointer 1218 70 t)
               (image:pointer 1218 70 nil))
             (let ((screen (screen-until (lambda (s) (and (= #xffd9d9d9 (image:pixel s 130 90))
                                                          (/= #xffffffff (image:pixel s 186 160)))))))
               (is (= #xffd9d9d9 (image:pixel screen 130 90)) "finder's window ~x" (image:pixel screen 130 90))
               (is (/= #xffffffff (image:pixel screen 186 160)) "a folder in it ~x" (image:pixel screen 186 160))))
        (image:finish c 5)))))

(test finch-edits-its-own-source
  (let ((disk (merge-pathnames "self-edit.img" (finch-file "build/")))
        (copy "(dolist (f (directory \"/usr/src/finch/**/*.*\")) (unless (uiop:directory-pathname-p f) (let ((to (concatenate 'string \"/Users/finch/src/finch/\" (subseq (namestring f) (length \"/usr/src/finch/\"))))) (ensure-directories-exist to) (uiop:copy-file f to))))")
        (edit "(let* ((p \"/Users/finch/src/finch/src/apps/session.lisp\") (text (uiop:read-file-string p)) (at (search \"(defun clock ()\" text))) (with-open-file (s p :direction :output :if-exists :supersede) (write-string (subseq text 0 at) s) (format s \"(defun clock () \\\"edited inside finch\\\")~%(defun clock-before ()\") (write-string (subseq text (+ at (length \"(defun clock ()\"))) s)) :edited)")
        (reload "(progn (handler-bind ((warning #'muffle-warning)) (asdf:load-system :finch/apps)) (list (namestring (asdf:system-source-file (asdf:find-system :finch/apps))) (finch/apps::clock)))"))
    (uiop:delete-file-if-exists disk)
    (let ((c (image:bare-console :root disk)))
      (flet ((ask (form) (image:send c form) (image:expect c (format nil "~%* ") :timeout 600)))
        (unwind-protect
             (progn
               (image:expect c "* " :timeout 60)
               (is (search "\"/Users/finch/" (ask "(namestring (asdf:apply-output-translations \"/usr/src/finch/finch.asd\"))"))
                   "fasls land in finch's home")
               (ask copy)
               (is (search ":EDITED" (ask edit)))
               (ask "(finch-asdf)")
               (is (search "(\"/Users/finch/src/finch/finch.asd\" \"edited inside finch\")" (ask reload)))
               (image:send c "(sb-ext:exit)")
               (image:expect c "exit(0)" :timeout 60))
          (image:finish c 5))))
    (let ((c (image:bare-console :root disk)))
      (flet ((ask (form) (image:send c form) (image:expect c (format nil "~%* ") :timeout 600)))
        (unwind-protect
             (progn
               (image:expect c "* " :timeout 60)
               (is (search "(\"/Users/finch/src/finch/finch.asd\" \"edited inside finch\")" (ask reload))
                   "the edit is there after a reboot"))
          (image:finish c 5))))))

(test finch-installs-a-generation-and-boots-it
  (let ((esp (merge-pathnames "esp-keep.img" (finch-file "build/"))))
    (uiop:delete-file-if-exists esp)
    (let ((c (image:bare-console :esp esp)))
      (flet ((ask (form) (image:send c form) (image:expect c (format nil "~%* ") :timeout 600)))
        (unwind-protect
             (progn
               (is (image:expect c "boot.efi: generation gen-1"))
               (image:expect c "* " :timeout 60)
               (is (search "(\"gen-1\")" (ask "(finch/install:generations)")))
               (is (search "\"gen-2\"" (ask "(finch/install:install \"/Volumes/EFI/EFI/finch/gen-1/kernel\" \"/Volumes/EFI/EFI/finch/gen-1/finch.core\")")))
               (is (search "(\"gen-1\" \"gen-2\")" (ask "(finch/install:generations)")))
               (image:send c "(sb-ext:exit)")
               (image:expect c "exit(0)" :timeout 60))
          (image:finish c 5))))
    (let ((c (image:bare-console :esp esp)))
      (flet ((ask (form) (image:send c form) (image:expect c (format nil "~%* ") :timeout 600)))
        (unwind-protect
             (progn
               (is (image:expect c "boot.efi: generation gen-2") "boot.efi boots what finch installed")
               (image:expect c "* " :timeout 60)
               (is (search "\"gen-2\"" (ask "(finch/install:current)"))))
          (image:finish c 5))))
    (is (zerop (nth-value 2 (uiop:run-program (list "fsck.fat" "-n" (uiop:native-namestring esp))
                                              :ignore-error-status t :output nil :error-output nil)))
        "fsck.fat passes the ESP finch wrote")))

(test finch-builds-its-kernel-and-boots-it
  (let ((esp (merge-pathnames "esp-kernel.img" (finch-file "build/")))
        (disk (merge-pathnames "guest-kernel.img" (finch-file "build/")))
        (copy "(dolist (f (directory \"/usr/src/finch/**/*.*\")) (unless (uiop:directory-pathname-p f) (let ((to (concatenate 'string \"/Users/finch/src/finch/\" (subseq (namestring f) (length \"/usr/src/finch/\"))))) (ensure-directories-exist to) (uiop:copy-file f to))))")
        (edit "(let* ((p \"/Users/finch/src/finch/src/osfmk/i386/init.lisp\") (text (uiop:read-file-string p)) (at (search \"RELEASE_X86_64\" text))) (with-open-file (s p :direction :output :if-exists :supersede) (write-string (subseq text 0 at) s) (write-string \"BUILT_IN_FINCH\" s) (write-string (subseq text (+ at (length \"RELEASE_X86_64\"))) s)) :edited)")
        (reload "(progn (handler-bind ((warning #'muffle-warning)) (asdf:load-system :finch/osfmk)) (namestring (asdf:system-source-file (asdf:find-system :finch/osfmk))))"))
    (uiop:delete-file-if-exists esp)
    (uiop:delete-file-if-exists disk)
    (let ((c (image:bare-console :esp esp :root disk)))
      (flet ((ask (form) (image:send c form) (image:expect c (format nil "~%* ") :timeout 600)))
        (unwind-protect
             (progn
               (is (image:expect c "root:finch/RELEASE_X86_64"))
               (image:expect c "* " :timeout 60)
               (ask copy)
               (is (search ":EDITED" (ask edit)))
               (ask "(finch-asdf)")
               (is (search "\"/Users/finch/src/finch/finch.asd\"" (ask reload)))
               (is (search "\"gen-2\"" (ask "(finch/install:install (finch/install:build-kernel) \"/Volumes/EFI/EFI/finch/gen-1/finch.core\")")))
               (image:send c "(sb-ext:exit)")
               (image:expect c "exit(0)" :timeout 60))
          (image:finish c 5))))
    (let ((c (image:bare-console :esp esp :root disk)))
      (flet ((ask (form) (image:send c form) (image:expect c (format nil "~%* ") :timeout 600)))
        (unwind-protect
             (progn
               (is (image:expect c "boot.efi: generation gen-2"))
               (is (image:expect c "root:finch/BUILT_IN_FINCH") "the kernel finch built is the one that boots")
               (image:expect c "* " :timeout 60)
               (is (search "\"gen-2\"" (ask "(finch/install:current)"))))
          (image:finish c 5))))))

(defun md5-hex (path)
  (string-downcase (format nil "~{~2,'0x~}" (coerce (sb-md5:md5sum-file path) 'list))))

(test finch-builds-its-c-and-boots-it
  (let* ((esp (merge-pathnames "esp-cc.img" (finch-file "build/")))
         (disk (merge-pathnames "guest-cc.img" (finch-file "build/")))
         (host (let ((image:*c-compiler* :tcc))
                 (image:mach-kernel)
                 (loop :for (name path) :in (finch/image::user-objects) :collect (cons name (md5-hex path)))))
         (sums "(progn (require :sb-md5) (mapcar (lambda (name) (cons name (string-downcase (format nil \"~{~2,'0x~}\" (coerce (sb-md5:md5sum-file (concatenate 'string \"/Users/finch/objects/\" name)) 'list))))) (mapcar #'(lambda (u) (getf u :name)) (finch/cc:units))))"))
    (uiop:delete-file-if-exists esp)
    (uiop:delete-file-if-exists disk)
    (let ((c (image:bare-console :esp esp :root disk)))
      (flet ((ask (form) (image:send c form) (image:expect c (format nil "~%* ") :timeout 1200)))
        (unwind-protect
             (progn
               (image:expect c "* " :timeout 60)
               (is (search "NIL" (ask "(finch/cc:compile-units \"/Users/finch/objects/\")")) "every C unit compiles inside finch")
               (let ((guest (read-from-string (ask sums))))
                 (is (equal host guest) "finch's TinyCC makes the host's objects byte for byte: ~a"
                     (set-difference guest host :test #'equal)))
               (is (search "\"gen-2\"" (ask "(finch/install:install (finch/install:build-kernel :objects \"/Users/finch/objects/\") \"/Volumes/EFI/EFI/finch/gen-1/finch.core\")")))
               (image:send c "(sb-ext:exit)")
               (image:expect c "exit(0)" :timeout 60))
          (image:finish c 5))))
    (let ((c (image:bare-console :esp esp :root disk)))
      (flet ((ask (form) (image:send c form) (image:expect c (format nil "~%* ") :timeout 600)))
        (unwind-protect
             (progn
               (is (image:expect c "boot.efi: generation gen-2"))
               (image:expect c "* " :timeout 60)
               (is (search "T" (ask "(finch/cc:compile-c \"src/libsa/string.c\" \"/tmp/string.o\" :directory \"/usr/src/finch/\")")))
               (is (search (cdr (assoc "libsa/string.o" host :test #'string=))
                           (ask "(progn (require :sb-md5) (string-downcase (format nil \"~{~2,'0x~}\" (coerce (sb-md5:md5sum-file \"/tmp/string.o\") 'list))))"))
                   "the TinyCC finch built makes the same object again"))
          (image:finish c 5))))))

(defun sbcl-phase (disk form marker)
  (let ((c (image:bare-console :root disk)))
    (unwind-protect
         (progn
           (image:expect c "* " :timeout 60)
           (image:send c "(progn (uiop:chdir \"/usr/src/sbcl/\") (setf *default-pathname-defaults* #p\"/usr/src/sbcl/\") (load \"loader.lisp\") :ready)")
           (image:expect c ":READY" :timeout 120)
           (image:send c form)
           (prog1 (or (ignore-errors (image:expect c marker :timeout 600))
                      (progn (format t "~&sbcl-phase: no ~a; console ends:~%~a~%" marker
                                     (let ((s (image:transcript c))) (subseq s (max 0 (- (length s) 3000)))))
                             nil))
             (image:send c "(progn (funcall (intern \"VFS-SYNC\" (or (find-package \"HOST-FINCH/VFS\") (find-package \"FINCH/VFS\")))) (format t \"~%SYNCED~%\"))")
             (image:expect c "SYNCED" :timeout 300)
             (image:send c "(funcall (intern \"EXIT\" (or (find-package \"HOST-SB-EXT\") (find-package \"SB-EXT\"))))")))
      (image:finish c 30))))

(defun disk-files (disk host-root guest-root relatives)
  (let ((finch/vfs:*root* nil) (finch/vfs:*mounts* nil))
    (finch/vfs:vfs-mount (finch/vfs:make-ram-node :vdir #o755) "/")
    (finch/vfs:vfs-mkdir "/root" #o755)
    (multiple-value-bind (read write) (finch/apfs:file-store disk)
      (finch/apfs:mount-writable read write "/root"))
    (loop :for rel :in relatives
          :for path := (concatenate 'string "/root/" guest-root rel)
          :unless (and (ignore-errors (finch/vfs:vfs-stat path))
                       (equalp (image::octets (merge-pathnames rel host-root))
                               (let ((fd (finch/vfs:vfs-open path (list :access :rdonly) 0)))
                                 (unwind-protect (finch/vfs:vfs-read fd (finch/vfs:vattr-size (finch/vfs:vfs-stat path)))
                                   (finch/vfs:vfs-close fd)))))
            :collect rel)))

(test finch-generates-its-bootstrap-inputs
  (let ((disk (merge-pathnames "inputs.img" (finch-file "build/"))))
    (uiop:delete-file-if-exists disk)
    (finch/image::root-disk disk (* 512 1048576)
                            (append (finch/image::root-entries) (finch/image::sbcl-source-entries)
                                    (finch/image::tree-entries (finch/image::tcc-source) "usr/src/tinycc")))
    (let ((c (image:bare-console :root disk)))
      (flet ((ask (form) (image:send c form) (image:expect c (format nil "~%* ") :timeout 600)))
        (unwind-protect
             (progn
               (image:expect c "* " :timeout 60)
               (ask "(defun same-files (a b names) (remove-if (lambda (n) (equalp (finch/build::file-octets (concatenate 'string a n)) (finch/build::file-octets (concatenate 'string b n)))) names))")
               (ask "(defun source-differences (a b) (remove-if-not (lambda (d) (member (pathname-type (second d)) '(\"c\" \"h\" \"S\" \"inc\" \"def\") :test #'equal)) (finch/build:tree-differences a b)))")
               (is (search "NIL"
                           (ask "(let ((id (string-trim '(#\\\" #\\Newline) (uiop:read-file-string \"/usr/src/sbcl/output/build-id.inc\")))) (finch/build:write-files \"/tmp/config/\" (finch/build:sbcl-config id)) (same-files \"/tmp/config/\" \"/usr/src/sbcl/\" (mapcar #'car (finch/build:sbcl-config id))))"))
                   "finch writes make-config's files as the host did")
               (is (search "NIL"
                           (ask "(progn (finch/build:runtime-tree \"/usr/src/sbcl/\" \"/usr/src/finch/src/sbcl/\" \"/tmp/runtime/\" :genesis \"/usr/src/finch/build/runtime/src/runtime/genesis/\") (source-differences \"/tmp/runtime/\" \"/usr/src/finch/build/runtime/\"))"))
                   "finch assembles the patched runtime tree from pristine SBCL")
               (is (search "(0 NIL)"
                           (ask "(list (finch/cc:run-c \"tools-for-build/grovel-headers.c\" :directory \"/usr/src/sbcl/\" :includes '(\"/tmp/runtime/src/runtime/\") :output \"/tmp/stuff-groveled-from-headers.lisp\") (same-files \"/tmp/\" \"/usr/src/sbcl/output/\" '(\"stuff-groveled-from-headers.lisp\")))"))
                   "grovel-headers runs inside finch and makes the host's constants byte for byte")
               (is (search "(0 NIL)"
                           (ask "(list (finch/cc:run-c \"conftest.c\" :directory \"/usr/src/tinycc/\" :defines '(\"C2STR\") :args '(\"include/tccdefs.h\" \"/tmp/tccdefs_.h\")) (progn (finch/build:libtcc-tree \"/usr/src/tinycc/\" \"/tmp/libtcc/\" \"/tmp/tccdefs_.h\") (finch/build:tree-differences \"/tmp/libtcc/\" \"/usr/src/finch/build/tcc/finch-src/\")))"))
                   "finch builds libtcc's tree, tccdefs_.h included, as the host did")
               (is (search "DIGESTS-MATCH"
                           (ask (format nil "(if (equal (finch/build:digest-tree \"/usr/src/finch/src/build/\") '~s) :digests-match :digests-differ)"
                                        (finch/build:digest-tree (finch-file "src/build/")))))
                   "finch's digests of its sources are the host's")
               (is (search "(3 (\"finch\" \"sbcl\" \"tinycc\"))"
                           (ask "(let ((m (finch/build:manifest :build-id \"test\" :sources '((\"finch\" \"/usr/src/finch/src/\") (\"sbcl\" \"/usr/src/sbcl/src/\") (\"tinycc\" \"/usr/src/tinycc/\"))))) (finch/build:write-manifest \"/tmp/manifest\" m) (let ((back (with-open-file (s \"/tmp/manifest\") (read s)))) (list (length (getf back :sources)) (mapcar #'first (getf back :sources)))))"))
                   "a manifest records every source file and reads back"))
          (image:finish c 5))))))

(test finch-runs-a-core-and-keeps-its-files
  (let ((esp (merge-pathnames "esp-run.img" (finch-file "build/")))
        (disk (merge-pathnames "run.img" (finch-file "build/")))
        (stress "(progn (ensure-directories-exist \"/work/f/\") (with-open-file (keep \"/work/keep.txt\" :direction :output) (dotimes (i 3000) (with-open-file (o (format nil \"/work/f/~d.txt\" i) :direction :output) (print i o))) (write-string \"kept\" keep)) (rename-file \"/work/f/0.txt\" \"/work/renamed.txt\") (with-open-file (o \"/work/count.txt\" :direction :output) (princ (length (directory \"/work/f/*.txt\")) o)))"))
    (uiop:delete-file-if-exists esp)
    (uiop:delete-file-if-exists disk)
    (finch/image::root-disk disk (* 256 1048576)
                            (append (finch/image::root-entries)
                                    (list (list :file "usr/lib/sbcl/sbcl.core" (image::octets (finch-file "build/sbcl-mt/output/sbcl.core"))))))
    (let ((c (image:bare-console :esp esp :root disk)))
      (flet ((ask (form) (image:send c form) (image:expect c (format nil "~%* ") :timeout 600))
             (run-in-core (code)
               (image:send c (format nil "(finch/run:run-core \"/usr/lib/sbcl/sbcl.core\" '~s :cwd \"/\")"
                                     (list "/System/Library/Kernels/kernel" "--core" "/System/Library/Kernels/finch.core"
                                           "--no-sysinit" "--no-userinit" "--disable-debugger" "--eval" code "--quit")))
               (image:expect c "restart: core" :timeout 300)
               (image:expect c "restart: core" :timeout 600)
               (image:expect c "* " :timeout 120)))
        (unwind-protect
             (progn
               (image:expect c "* " :timeout 60)
               (image:send c "(finch/install:save)")
               (is (image:expect c "restart: core " :timeout 300) "finch runs from a saved core")
               (image:expect c "* " :timeout 120)
               (ask "(progn (with-open-file (s \"/tmp/good.c\" :direction :output :if-exists :supersede) (write-line \"int good(void) { return 1; }\" s)) (with-open-file (s \"/tmp/bad.c\" :direction :output :if-exists :supersede) (write-line \"int bad(void) { return }\" s)) (ensure-directories-exist \"/tmp/u/\") (with-open-file (s \"/tmp/u/bad.o\" :direction :output :if-exists :supersede) (write-line \"stale\" s)) :written)")
               (ask "(with-open-file (s \"/tmp/hello.c\" :direction :output :if-exists :supersede) (write-line \"#include <stdio.h>\" s) (write-line \"int main(int argc, char **argv) { printf(\\\"hello %d %s\\\\n\\\", 6 * 7, argv[1]); return 3; }\" s))")
               (is (search "(3 \"hello 42 finch"
                           (ask "(list (finch/cc:run-c \"/tmp/hello.c\" :args '(\"finch\") :output \"/tmp/hello.out\") (uiop:read-file-string \"/tmp/hello.out\"))"))
                   "TinyCC runs a C program inside finch")
               (is (search "(\"bad.o\")" (ask "(finch/cc:compile-units \"/tmp/u/\" :directory \"/tmp/\" :units '((:name \"good.o\" :source \"good.c\") (:name \"bad.o\" :source \"bad.c\")))"))
                   "the failed unit is reported")
               (is (search "(T NIL NIL)" (ask "(list (and (probe-file \"/tmp/u/good.o\") t) (probe-file \"/tmp/u/bad.o\") (probe-file \"/tmp/u/objects\"))"))
                   "a failed build leaves no stale object and no link list")
               (run-in-core stress)
               (is (search "(:EXIT 0 :FILES 3002)" (ask "(finch/run:collect)")) "every file the run wrote comes back")
               (is (search "(\"kept\" \"2999\" T)"
                           (ask "(list (uiop:read-file-string \"/work/keep.txt\") (uiop:read-file-string \"/work/count.txt\") (and (probe-file \"/work/renamed.txt\") t))"))
                   "an open file, a rename and a directory listing survive 3000 new files")
               (run-in-core "(progn (with-open-file (o \"/work/failed.txt\" :direction :output) (write-string \"partial\" o)) (sb-ext:exit :code 3))")
               (is (search "(:EXIT 3 :FILES 0 :REJECTED 1)" (ask "(finch/run:collect)")) "a failed run's files are rejected")
               (is (search "NIL" (ask "(probe-file \"/work/failed.txt\")")) "and never reach the disk"))
          (image:finish c 5))))))

(defvar *run-wait* 1800)

(defun sbcl-run (disk core argv &key stdin script (files t))
  (let ((c (image:bare-console :root disk)))
    (unwind-protect
         (progn
           (image:expect c "* " :timeout 60)
           (when script
             (image:send c (format nil "(progn (with-open-file (s ~s :direction :output :if-exists :supersede) (write-string ~s s)) :stdin)" stdin script))
             (image:expect c ":STDIN" :timeout 60))
           (image:send c (format nil "(finch/run:run-core ~s '~s :cwd \"/usr/src/sbcl\"~:[~; :files (finch/run:tree-files \"/usr/src/sbcl/\" :keep (lambda (f) (let ((n (namestring f))) (not (or (search \"/obj/from-host/\" n) (search \"/obj/from-xc/\" n) (search \".core\" n))))))~]~@[ :stdin ~s~])"
                                 core argv files stdin))
           (image:expect c "restart: core" :timeout 300)
           (unless (ignore-errors (image:expect c "restart: core" :timeout *run-wait*))
             (format t "~&sbcl-run: no return; console ends:~%~a~%" (let ((s (image:transcript c))) (subseq s (max 0 (- (length s) 3000)))))
             (finish-output)
             (return-from sbcl-run nil))
           (image:expect c "* " :timeout 120)
           (image:send c "(finch/run:collect)")
           (prog1 (image:expect c (format nil "~%* ") :timeout 600)
             (image:send c "(progn (finch/vfs:vfs-sync) (sb-ext:exit))")
             (image:expect c "exit(0)" :timeout 120)))
      (image:finish c 30))))

(defun dump-script ()
  (let* ((script (uiop:read-file-string (finch-file "build/sbcl-mt/make-target-2.sh")))
         (start (+ (search (format nil "<<EOF~%") script) 6))
         (body (subseq script start (1+ (search (format nil "~%EOF") script :start2 start))))
         (at (search "${devel}" body)))
    (concatenate 'string (subseq body 0 at) (subseq body (+ at 8)))))

(test finch-bootstraps-sbcl
  (let ((disk (merge-pathnames "sbcl-build.img" (finch-file "build/")))
        (host (finch-file "build/sbcl-mt/"))
        (kernel "/System/Library/Kernels/kernel")
        (core "/System/Library/Kernels/finch.core"))
    (uiop:delete-file-if-exists disk)
    (finch/image::root-disk disk (* 512 1048576) (append (finch/image::root-entries) (finch/image::sbcl-source-entries)))
    (is (sbcl-phase disk "(progn (cl-user::load-sbcl-file \"make-host-1.lisp\" nil) (format t \"~%HOST1-DONE~%\"))" "HOST1-DONE")
        "make-host-1 builds the cross-compiler inside finch")
    (is (sbcl-phase disk "(progn (push (lambda () (throw 'after-xc t)) sb-ext:*save-hooks*) (catch 'after-xc (cl-user::load-sbcl-file \"make-host-2.lisp\" nil)) (format t \"~%HOST2-DONE~%\"))" "HOST2-DONE")
        "make-host-2 cross-compiles the target inside finch")
    (is (sbcl-phase disk "(progn (cl-user::load-sbcl-file \"make-genesis-2.lisp\" nil) (format t \"~%GENESIS2-DONE~%\"))" "GENESIS2-DONE")
        "make-genesis-2 writes the cold core inside finch")
    (flet ((relatives (pattern) (mapcar (lambda (p) (enough-namestring p host)) (directory (merge-pathnames pattern host)))))
      (let ((files (append (list "output/cold-sbcl.core")
                           (relatives "output/genesis-2/*.h") (relatives "src/runtime/genesis/*.h")
                           (relatives "obj/from-xc/**/*.lisp-obj"))))
        (is (null (disk-files disk host "usr/src/sbcl/" files))
            "finch's cold core, headers and target fasls are the host's byte for byte (~d files)" (length files))))
    (is (search "(:EXIT 0"
                (sbcl-run disk "/usr/src/sbcl/output/cold-sbcl.core"
                          (list kernel "--core" core "--lose-on-corruption" "--no-sysinit" "--no-userinit"
                                "--eval" "(sb-fasl::!warm-load \"src/cold/warm.lisp\")" "--quit")))
        "the cold core does warm init's compile phase inside finch")
    (is (search "(:EXIT 0 :FILES 1)"
                (sbcl-run disk "/usr/src/sbcl/output/cold-sbcl.core"
                          (list kernel "--noinform" "--core" core "--lose-on-corruption" "--no-sysinit" "--no-userinit" "--noprint")
                          :stdin "/usr/src/sbcl/output/target-2-dump.lisp" :script (dump-script)))
        "the cold core loads warm init and saves sbcl.core inside finch")
    (sbcl-run disk "/usr/src/sbcl/output/sbcl.core"
              (list kernel "--core" core "--no-sysinit" "--no-userinit" "--disable-debugger" "--eval"
                    "(with-open-file (o \"/usr/src/sbcl/new-core.txt\" :direction :output :if-exists :supersede) (prin1 (list (lisp-implementation-version) (funcall (compile nil '(lambda (n) (loop for i from 1 to n sum (* i i)))) 100) (class-name (find-class 'standard-object))) o))"
                    "--quit")
              :files nil)
    (is (equal "(\"2.6.4.finch\" 338350 STANDARD-OBJECT)"
               (let ((out (disk-octets disk "usr/src/sbcl/new-core.txt"))) (and out (map 'string #'code-char out))))
        "the sbcl.core finch built runs, compiles and has CLOS")))

(defun disk-octets (disk relative)
  (let ((finch/vfs:*root* nil) (finch/vfs:*mounts* nil))
    (finch/vfs:vfs-mount (finch/vfs:make-ram-node :vdir #o755) "/")
    (finch/vfs:vfs-mkdir "/root" #o755)
    (multiple-value-bind (read write) (finch/apfs:file-store disk)
      (finch/apfs:mount-writable read write "/root"))
    (let ((path (concatenate 'string "/root/" relative)))
      (when (ignore-errors (finch/vfs:vfs-stat path))
        (let ((fd (finch/vfs:vfs-open path (list :access :rdonly) 0)))
          (unwind-protect (finch/vfs:vfs-read fd (finch/vfs:vattr-size (finch/vfs:vfs-stat path)))
            (finch/vfs:vfs-close fd)))))))

(defun host-build-octets (path host)
  (let* ((octets (image::octets path))
         (runtime (sb-ext:string-to-octets (namestring (merge-pathnames "src/runtime/sbcl" host))))
         (tree (sb-ext:string-to-octets (namestring host)))
         (out (make-array 0 :element-type '(unsigned-byte 8) :adjustable t :fill-pointer 0)))
    (flet ((put (v) (loop :for b :across v :do (vector-push-extend b out))))
      (let ((i 0))
        (loop
          (let ((r (search runtime octets :start2 i))
                (s (search tree octets :start2 i)))
            (cond ((and r (or (null s) (<= r s)))
                   (put (subseq octets i r))
                   (put (sb-ext:string-to-octets "/System/Library/Kernels/kernel"))
                   (setf i (+ r (length runtime))))
                  (s
                   (let* ((length (aref octets (1- s)))
                          (path (sb-ext:string-to-octets
                                 (concatenate 'string "/usr/src/sbcl/"
                                              (sb-ext:octets-to-string (subseq octets (+ s (length tree)) (+ s length)))))))
                     (put (subseq octets i (1- s)))
                     (vector-push-extend (length path) out)
                     (put path)
                     (setf i (+ s length))))
                  (t (put (subseq octets i)) (return)))))))
    (coerce out '(simple-array (unsigned-byte 8) (*)))))

(defun generation-resume (c steps)
  (loop
    (image:send c (format nil "(format t \"~~%RESUME~~a ~~s~~%\" \"D\" (finch/generation:resume ~a))" steps))
    (multiple-value-bind (seen found) (image:expect c (list "RESUMED " "restart: core") :timeout 1200)
      (declare (ignore seen))
      (when (string= found "RESUMED ")
        (let ((result (read-from-string (image:expect c (string #\Newline) :timeout 60))))
          (unless (eq :done (first result))
            (format t "~&generation-resume: ~s; console ends:~%~a~%" result (let ((s (image:transcript c))) (subseq s (max 0 (- (length s) 6000))))))
          (return result)))
      (unless (ignore-errors (image:expect c "restart: core" :timeout *run-wait*))
        (format t "~&generation-resume: no return; console ends:~%~a~%" (let ((s (image:transcript c))) (subseq s (max 0 (- (length s) 3000)))))
        (return nil))
      (image:expect c "* " :timeout 120))))

(test finch-builds-its-contribs
  (let ((disk (merge-pathnames "sbcl-build.img" (finch-file "build/")))
        (host (finch-file "build/sbcl-mt/"))
        (fasls '("uiop" "asdf" "sb-rotate-byte" "sb-md5" "sb-posix" "sb-bsd-sockets")))
    (is (disk-octets disk "usr/src/sbcl/output/sbcl.core") "finch-bootstraps-sbcl left finch's own sbcl.core")
    (let ((c (image:bare-console :root disk)))
      (flet ((ask (form) (image:send c form) (image:expect c (format nil "~%* ") :timeout 600)))
        (unwind-protect
             (progn
               (image:expect c "* " :timeout 60)
               (ask "(uiop:delete-file-if-exists finch/generation:*state*)")
               (ask "(progn (mapc #'delete-file (directory \"/usr/src/sbcl/obj/sbcl-home/contrib/*.*\")) (uiop:delete-directory-tree #p\"/usr/src/sbcl/obj/from-self/\" :validate t :if-does-not-exist :ignore))")
               (is (search "NIL" (ask "(append (directory \"/usr/src/sbcl/obj/sbcl-home/contrib/*.*\") (directory \"/usr/src/sbcl/obj/from-self/**/*.*\"))")) "no contrib output is left from before")
               (let ((result (generation-resume c "(finch/generation:contrib-steps \"/usr/src/sbcl/\")")))
                 (is (eq :done (first result)) "every contrib step finishes: ~s" result))
               (image:send c "(progn (finch/vfs:vfs-sync) (sb-ext:exit))")
               (image:expect c "exit(0)" :timeout 120))
          (image:finish c 30))))
    (dolist (name '("sb-posix" "sb-bsd-sockets"))
      (let ((rel (format nil "obj/from-self/contrib/~a/generated-constants.lisp" name)))
        (is (equalp (image::octets (merge-pathnames rel host)) (disk-octets disk (concatenate 'string "usr/src/sbcl/" rel)))
            "~a's grovel output in finch is the host's byte for byte" name)))
    (let ((built (remove-if-not (lambda (name) (disk-octets disk (format nil "usr/src/sbcl/obj/sbcl-home/contrib/~a.fasl" name))) fasls)))
      (is (equal fasls built) "finch built ~a" built)
      (flet ((differing (name)
               (let ((h (host-build-octets (merge-pathnames (format nil "obj/sbcl-home/contrib/~a.fasl" name) host) host))
                     (g (disk-octets disk (format nil "usr/src/sbcl/obj/sbcl-home/contrib/~a.fasl" name))))
                 (if (= (length h) (length g)) (count nil (map 'list #'= h g)) :length))))
        (dolist (name '("uiop" "asdf" "sb-rotate-byte" "sb-md5"))
          (is (eql 0 (differing name)) "~a.fasl is the host's byte for byte, but for where each runtime and source tree lives" name))
        (dolist (name '("sb-posix" "sb-bsd-sockets"))
          (is (eql 4 (differing name)) "~a.fasl is the host's but for its generated constants' build date" name))))
    (sbcl-run disk "/usr/src/sbcl/output/sbcl.core"
              (list "/System/Library/Kernels/kernel" "--core" "/System/Library/Kernels/finch.core" "--no-sysinit" "--no-userinit" "--disable-debugger" "--eval"
                    "(progn (setf sb-sys::*sbcl-homedir-pathname* #p\"/usr/src/sbcl/obj/sbcl-home/\") (require :asdf) (require :sb-md5) (require :sb-posix) (require :sb-bsd-sockets))"
                    "--eval" "(with-open-file (o \"/usr/src/sbcl/contribs.txt\" :direction :output :if-exists :supersede) (write (list (asdf:asdf-version) (sb-md5:md5sum-string \"finch\") (integerp (sb-posix:getpid)) (sb-bsd-sockets:make-inet-address \"10.0.2.2\")) :stream o :pretty nil))"
                    "--quit"))
    (is (equal "(\"3.3.1\" #(192 65 240 164 75 149 198 213 199 195 255 71 232 234 151 51) T #(10 0 2 2))"
               (let ((out (disk-octets disk "usr/src/sbcl/contribs.txt"))) (and out (map 'string #'code-char out))))
        "finch's sbcl.core loads the contribs finch built, and they work")))

(test finch-saves-itself-and-boots-the-save
  (let ((esp (merge-pathnames "esp-save.img" (finch-file "build/"))))
    (uiop:delete-file-if-exists esp)
    (let ((c (image:bare-console :esp esp)))
      (flet ((ask (form) (image:send c form) (image:expect c (format nil "~%* ") :timeout 600)))
        (unwind-protect
             (progn
               (image:expect c "* " :timeout 60)
               (ask "(defvar cl-user::*made-in-finch* :made-in-finch)")
               (image:send c "(finch/install:save)")
               (is (image:expect c "restart: core " :timeout 300) "the save restarts the runtime on it")
               (image:expect c "* " :timeout 120)
               (is (search ":MADE-IN-FINCH" (ask "cl-user::*made-in-finch*")) "the restarted image is the saved one")
               (is (search "\"gen-2\"" (ask "(finch/install:install \"/System/Library/Kernels/kernel\" \"/System/Library/Kernels/finch.core\")")))
               (image:send c "(sb-ext:exit)")
               (image:expect c "exit(0)" :timeout 60))
          (image:finish c 5))))
    (let ((c (image:bare-console :esp esp)))
      (flet ((ask (form) (image:send c form) (image:expect c (format nil "~%* ") :timeout 600)))
        (unwind-protect
             (progn
               (is (image:expect c "boot.efi: generation gen-2"))
               (image:expect c "* " :timeout 60)
               (is (search ":MADE-IN-FINCH" (ask "cl-user::*made-in-finch*")) "gen-2 is the image finch saved"))
          (image:finish c 5))))))

(defun listener-line (file prefix)
  (position-if (lambda (line) (uiop:string-prefix-p prefix line))
               (uiop:split-string (or (ignore-errors (uiop:read-file-string file)) "") :separator '(#\Newline))))

(test listener-on-finch
  (let ((c (image:bare-console :boot-args "launchd")))
    (flet ((ask (form) (image:send c form) (image:expect c (format nil "~%* ") :timeout 60))
           (click (x y) (image:pointer x y) (image:pointer x y t) (image:pointer x y nil))
           (type-slowly (text) (loop :for ch :across text :do (image:send-keys (string ch)) (sleep 0.002))))
      (flet ((transcript (file until)
               (loop :with deadline := (+ (get-internal-real-time) (* 30 internal-time-units-per-second))
                     :do (let ((text (ask (format nil "(progn (ignore-errors (finch/shell:cat ~s)) :done)" file))))
                           (when (or (search until text) (> (get-internal-real-time) deadline))
                             (return text)))
                         (sleep 0.2)))
             (line-y (index) (+ 90 40 4 (* index 17) 8)))
        (unwind-protect
             (progn
               (is (image:expect c "load_init_program: /sbin/launchd pid 1" :timeout 90))
               (image:expect c "launchd: pid 1")
               (sleep 3)
               (click 707 744)
               (is (search "* " (transcript "/tmp/Listener.txt" "* ")) "the listener opens")
               (is (= #xffffffff (image:pixel (screen-until (lambda (s) (= #xffffffff (image:pixel s 400 500))))
                                              400 500))
                   "the listener's window")
               (click 400 500)
               (type-slowly (format nil "(list 1 \"two\" :three)~%"))
               (let ((text (transcript "/tmp/Listener.txt" "> (1 \"two\" :THREE)")))
                 (is (search "> (1 \"two\" :THREE)" text) "the value is a presentation: ~s" text))
               (let ((index (ask (format nil "(finch/test::listener-line \"/tmp/Listener.txt\" \"> (1\")"))))
                 (click 260 (line-y (parse-integer index :junk-allowed t :start (position-if #'digit-char-p index)))))
               (let ((text (transcript "/tmp/Inspector.txt" "0: 1")))
                 (is (search ">   0: 1" text) "clicking the value inspects it: ~s" text)
                 (is (search ">   1: \"two\"" text)))
               (click 400 500)
               (type-slowly (format nil "(car 1)~%"))
               (let ((text (transcript "/tmp/Listener.txt" "restart: Return to the listener")))
                 (is (search "> error: " text) "~s" text)
                 (is (search "restart: Return to the listener" text)))
               (let ((index (ask (format nil "(finch/test::listener-line \"/tmp/Listener.txt\" \">   restart: Return to the listener\")"))))
                 (click 260 (line-y (parse-integer index :junk-allowed t :start (position-if #'digit-char-p index)))))
               (click 400 500)
               (type-slowly (format nil "(+ 2 3)~%"))
               (let ((text (transcript "/tmp/Listener.txt" "> 5")))
                 (is (search "> 5" text) "the listener goes on after the restart: ~s" text))
               (type-slowly (format nil "(defun boom (x) (error \"boom ~~a\" (* x 2)))~%"))
               (transcript "/tmp/Listener.txt" "> BOOM")
               (type-slowly (format nil "(boom 21)~%"))
               (let ((text (transcript "/tmp/Listener.txt" "frame: (BOOM 21)")))
                 (is (search ">   frame: (BOOM 21)" text) "the error shows its frames: ~s" text))
               (let ((index (ask (format nil "(finch/test::listener-line \"/tmp/Listener.txt\" \">   frame: (BOOM 21)\")"))))
                 (click 260 (line-y (parse-integer index :junk-allowed t :start (position-if #'digit-char-p index)))))
               (let ((text (transcript "/tmp/Inspector.txt" "arg 0: 21")))
                 (is (search ">   arg 0: 21" text) "clicking a frame inspects its arguments: ~s" text)
                 (is (search "function: BOOM" text))))
          (image:finish c 5))))))

(test editor-on-finch
  (let ((c (image:bare-console :boot-args "launchd")))
    (flet ((ask (form) (image:send c form) (image:expect c (format nil "~%* ") :timeout 60))
           (click (x y) (image:pointer x y) (image:pointer x y t) (image:pointer x y nil))
           (type-slowly (text) (loop :for ch :across text :do (image:send-keys (string ch)) (sleep 0.002))))
      (flet ((transcript (file until)
               (loop :with deadline := (+ (get-internal-real-time) (* 30 internal-time-units-per-second))
                     :do (let ((text (ask (format nil "(progn (ignore-errors (finch/shell:cat ~s)) :done)" file))))
                           (when (or (search until text) (> (get-internal-real-time) deadline))
                             (return text)))
                         (sleep 0.2))))
        (unwind-protect
             (progn
               (is (image:expect c "load_init_program: /sbin/launchd pid 1" :timeout 90))
               (image:expect c "launchd: pid 1")
               (sleep 3)
               (click 707 744)
               (screen-until (lambda (s) (= #xffffffff (image:pixel s 400 500))))
               (click 400 500)
               (type-slowly (format nil "(ed \"/tmp/twice.lisp\")~%"))
               (is (search "twice.lisp" (transcript "/tmp/Editor.txt" "twice.lisp")) "ed opens an editor")
               (screen-until (lambda (s) (= #xffffffff (image:pixel s 600 560))))
               (click 600 560)
               (type-slowly (format nil "(defun twice (x)~%(* 2 x))"))
               (type-slowly (coerce (list (code-char 24) (code-char 19)) 'string))
               (let ((text (transcript "/tmp/Editor.txt" "wrote /tmp/twice.lisp")))
                 (is (search "wrote /tmp/twice.lisp" text) "C-x C-s saves: ~s" text))
               (is (search (format nil "(defun twice (x)~%(* 2 x))") (ask "(progn (finch/shell:cat \"/tmp/twice.lisp\") :done)")))
               (type-slowly (coerce (list (code-char #xF700) (code-char 3) (code-char 3)) 'string))
               (let ((text (transcript "/tmp/Editor.txt" "TWICE")))
                 (is (search "TWICE" text) "C-c C-c evaluates the form: ~s" text))
               (click 210 400)
               (type-slowly (format nil "(twice 21)~%"))
               (let ((text (transcript "/tmp/Listener.txt" "> 42")))
                 (is (search "> 42" text) "the listener calls what the editor defined: ~s" text)))
          (image:finish c 5))))))
