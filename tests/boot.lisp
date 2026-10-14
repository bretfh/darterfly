(in-package #:finch/test)

(def-suite boot :in all)
(in-suite boot)

(test boot-efi-starts-the-kernel
  (let ((c (image:bare-console :boot-args "halt" :root nil)))
    (unwind-protect
         (progn
           (is (image:expect c "finch boot.efi"))
           (is (search "rsdp 0x" (image:expect c "boot-args \"halt\"")))
           (is (image:expect c "finch Kernel Version"))
           (is (image:expect c "boot_args: Revision 1 Version 2 efiMode 64"))
           (is (search "kslide 0x" (image:expect c "memory:")))
           (is (search "MB usable" (image:expect c "video: 1280x800x32")))
           (is (image:expect c (format nil "~%halt"))))
      (image:finish c 5))))

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
         (c (image:bare-console :root disk)))
    (flet ((ask (form) (image:send c form) (image:expect c (format nil "~%* ") :timeout 120)))
      (unwind-protect
           (progn
             (image:expect c "* " :timeout 60)
             (is (search "APFS-WVNODE" (ask "(type-of (finch/vfs:namei \"/\"))")))
             (is (search "\"finch HD\"" (ask "(iokit:get-property (find \"disk2s1\" (iokit:find-entries 'finch/apfs::apple-apfs-volume) :key (lambda (e) (iokit:get-property e \"BSD Name\")) :test #'equal) \"FullName\")")))
             (is (search "334" (ask "(length (uiop:read-file-lines \"/finch/tests/ports.txt\"))")))
             (is (search "#P\"/System/Library/Kernels/kernel\"" (ask "(probe-file \"/System/Library/Kernels/kernel\")")))
             (is (search "DEV-NODE" (ask "(type-of (finch/vfs:namei \"/dev/console\"))")))
             (ask "(with-open-file (s \"/Users/finch/notes.txt\" :direction :output) (write-line \"kept across boots\" s))")
             (image:send c "(sb-ext:exit)")
             (image:expect c "exit(0)" :timeout 30))
        (image:finish c 5))
      (let ((v (first (apfs:container-volumes (apfs:open-container (apfs:file-device disk))))))
        (is (equal "finch HD" (apfs:volume-name v)))
        (is (equal (format nil "kept across boots~%")
                   (map 'string #'code-char (apfs:read-file v (apfs:lookup v "/Users/finch/notes.txt")))))))))

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
