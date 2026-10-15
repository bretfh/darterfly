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
             (is (search ":LOADED" (ask "(progn (require :sb-rotate-byte) (require :sb-md5) :loaded)")) "contribs from SBCL_HOME")
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
