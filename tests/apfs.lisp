(in-package #:darterfly/test)

(def-suite apfs :in all)
(in-suite apfs)

(defun text (s) (sb-ext:string-to-octets s :external-format :utf-8))

(defun newfs-entries ()
  (append (list '(:dir "System") '(:dir "System/Library")
                (list :file "System/Library/name" (text (format nil "darterfly~%")))
                (list :file "hello.txt" (text (format nil "hello from darterfly~%")))
                '(:symlink "link" "hello.txt")
                (list :file "big.txt" (text (with-output-to-string (s)
                                              (dotimes (i 20000) (format s "line ~5,'0d of a file darterfly wrote~%" i)))))
                (list :file "café.txt" (text (format nil "accent~%")))
                '(:dir "many"))
          (loop for i from 1 to 300 collect (list :file (format nil "many/f~d" i) (text (format nil "file ~d~%" i))))))

(defun newfs-image ()
  (apfs:newfs (merge-pathnames "newfs.img" (darterfly-file "build/")) :volume-name "darterfly" :entries (newfs-entries)))

(defun image-volume (image)
  (first (apfs:container-volumes (apfs:open-container (apfs:file-device image)))))

(defun file-text (v path)
  (let ((id (apfs:lookup v path)))
    (and id (sb-ext:octets-to-string (apfs:read-file v id) :external-format :utf-8))))

(test newfs-reads-back
  (let ((v (image-volume (newfs-image))))
    (is (equal "darterfly" (apfs:volume-name v)))
    (is (null (apfs:lookup v "/not/there")))
    (dolist (e (newfs-entries))
      (destructuring-bind (kind path &optional content) e
        (let ((id (apfs:lookup v (concatenate 'string "/" path))))
          (is (not (null id)) "~a is there" path)
          (when id
            (let ((mode (apfs:inode-mode (apfs:inode v id))))
              (ecase kind
                (:dir (is (= #o040755 mode) "~a: mode ~o" path mode))
                (:symlink (is (= #o120000 (logand mode #o170000))) (is (equal content (apfs:readlink v id))))
                (:file (is (= #o100000 (logand mode #o170000)))
                 (is (equalp content (apfs:read-file v id)) "~a: contents" path))))))))
    (is (= 300 (length (apfs:directory-entries v (apfs:lookup v "/many")))))
    (is (equal "line 12345 of a" (map 'string #'code-char (apfs:read-file v (apfs:lookup v "/big.txt") :start (* 12345 33) :end (+ (* 12345 33) 15)))))))

(defun put-file (path content)
  (let ((fd (darterfly/vfs:vfs-open path (list :access :wronly :creat t :trunc t) #o644)))
    (darterfly/vfs:vfs-write fd (text content))
    (darterfly/vfs:vfs-close fd)))

(defun big-text ()
  (let ((big (with-output-to-string (s) (dotimes (i 8000) (format s "darterfly line ~5,'0d~%" i)))))
    (replace big "PATCHED" :start1 4096)))

(defun write-image ()
  (let* ((image (newfs-image))
         (tick (* 1000000000 1791940000))
         (apfs:*clock* (lambda () (incf tick 1000)))
         (darterfly/vfs:*root* nil)
         (darterfly/vfs:*mounts* nil))
    (darterfly/vfs:vfs-mount (darterfly/vfs:make-ram-node :vdir #o755) "/")
    (darterfly/vfs:vfs-mkdir "/mnt" #o755)
    (multiple-value-bind (r w) (apfs:file-store image) (apfs:mount-writable r w "/mnt"))
    (darterfly/vfs:vfs-mkdir "/mnt/new" #o755)
    (put-file "/mnt/new/a.txt" (format nil "written by darterfly~%"))
    (put-file "/mnt/new/big.txt" (with-output-to-string (s) (dotimes (i 8000) (format s "darterfly line ~5,'0d~%" i))))
    (let ((fd (darterfly/vfs:vfs-open "/mnt/new/big.txt" (list :access :rdwr) 0)))
      (darterfly/vfs:vfs-write fd (text "PATCHED") 4096)
      (darterfly/vfs:vfs-close fd))
    (darterfly/vfs:vfs-symlink "a.txt" "/mnt/new/link")
    (darterfly/vfs:vfs-rename "/mnt/hello.txt" "/mnt/new/hello2.txt")
    (loop for i from 1 to 50 do (darterfly/vfs:vfs-unlink (format nil "/mnt/many/f~d" i)))
    (put-file "/mnt/System/Library/name" (format nil "darterfly rewrote this~%"))
    (darterfly/vfs:vnop-setattr (darterfly/vfs:namei "/mnt/new/a.txt") :mode #o600)
    (darterfly/vfs:vfs-mkdir "/mnt/gone" #o755)
    (darterfly/vfs:vfs-remove "/mnt/gone" t)
    image))

(test writes-read-back
  (let ((v (image-volume (write-image))))
    (is (equal (format nil "written by darterfly~%") (file-text v "/new/a.txt")))
    (is (= #o600 (logand #o7777 (apfs:inode-mode (apfs:inode v (apfs:lookup v "/new/a.txt"))))))
    (is (equal (big-text) (file-text v "/new/big.txt")))
    (is (equal (format nil "darterfly rewrote this~%") (file-text v "/System/Library/name")))
    (is (equal "a.txt" (apfs:readlink v (apfs:lookup v "/new/link"))))
    (is (equal (format nil "hello from darterfly~%") (file-text v "/new/hello2.txt")))
    (is (null (apfs:lookup v "/hello.txt")))
    (is (null (apfs:lookup v "/many/f1")))
    (is (null (apfs:lookup v "/gone")))
    (is (apfs:lookup v "/many/f51"))
    (is (= 250 (length (apfs:directory-entries v (apfs:lookup v "/many")))))))

(test update-root-keeps-what-is-not-the-system
  (let ((disk (merge-pathnames "update-root.img" (darterfly-file "build/"))))
    (apfs:newfs disk :volume-name "darterfly HD"
                     :entries (list '(:dir "Users") '(:dir "System")
                                    (list :file "Users/notes.txt" (text "mine")) (list :file "System/name" (text "old"))))
    (image:update-root disk (list '(:dir "System") '(:dir "System/Library")
                                  (list :file "System/name" (text "new system"))
                                  (list :file "System/Library/added" (text "added") #o100755)))
    (let* ((v (first (apfs:container-volumes (apfs:open-container (apfs:file-device disk)))))
           (read (lambda (path) (map 'string #'code-char (apfs:read-file v (apfs:lookup v path))))))
      (is (equal "mine" (funcall read "/Users/notes.txt")))
      (is (equal "new system" (funcall read "/System/name")))
      (is (equal "added" (funcall read "/System/Library/added")))
      (is (= #o100755 (apfs:inode-mode (apfs:inode v (apfs:lookup v "/System/Library/added"))))))))

(test update-root-rewrites-many-files-in-one-transaction
  (let ((disk (merge-pathnames "update-many.img" (darterfly-file "build/")))
        (files (lambda (tag) (cons '(:dir "many")
                                   (loop :for i :below 2000
                                         :collect (list :file (format nil "many/f~d" i) (text (format nil "~a ~d" tag i))))))))
    (apfs:newfs disk :size (* 64 1048576) :volume-name "darterfly HD" :entries '((:dir "Users")))
    (image:update-root disk (funcall files "first"))
    (image:update-root disk (funcall files "second"))
    (let* ((v (first (apfs:container-volumes (apfs:open-container (apfs:file-device disk)))))
           (read (lambda (path) (map 'string #'code-char (apfs:read-file v (apfs:lookup v path))))))
      (is (= 2000 (length (apfs:directory-entries v (apfs:lookup v "/many")))))
      (is (equal "second 1999" (funcall read "/many/f1999"))))
    (delete-file disk)))

(test a-free-queue-too-big-for-one-node-carries-over
  (let ((disk (merge-pathnames "carry.img" (darterfly-file "build/")))
        (darterfly/vfs:*root* nil)
        (darterfly/vfs:*mounts* nil))
    (apfs:newfs disk :size (* 64 1048576) :volume-name "darterfly HD" :entries '((:dir "Users")))
    (image:update-root disk (cons '(:dir "many") (loop :for i :below 2000
                                                       :collect (list :file (format nil "many/f~d" i) (make-array 5000 :element-type '(unsigned-byte 8) :initial-element (mod i 256))))))
    (darterfly/vfs:vfs-mount (darterfly/vfs:make-ram-node :vdir #o755) "/")
    (darterfly/vfs:vfs-mkdir "/mnt" #o755)
    (multiple-value-bind (r w) (apfs:file-store disk) (apfs:mount-writable r w "/mnt"))
    (apfs:with-batch
      (loop :for i :from 0 :below 2000 :by 2 :do (darterfly/vfs:vfs-unlink (format nil "/mnt/many/f~d" i))))
    (image:update-root disk (list (list :file "many/after" (text "still writable"))))
    (let* ((v (first (apfs:container-volumes (apfs:open-container (apfs:file-device disk)))))
           (read (lambda (path) (map 'string #'code-char (apfs:read-file v (apfs:lookup v path))))))
      (is (= 1001 (length (apfs:directory-entries v (apfs:lookup v "/many")))))
      (is (equal "still writable" (funcall read "/many/after"))))
    (delete-file disk)))

(test a-root-one-entry-too-full-splits
  (let* ((records (loop :for i :below 112 :collect (cons (apfs::octets (apfs::le i 8) (apfs::le 1 8)) (apfs::le i 16))))
         (nodes (apfs::pack-btree records :fixed t :key-size 16 :value-size 16 :info-flags #x12 :subtype #xb
                                          :physical t :xid 1 :next-oid (let ((n 100)) (lambda () (incf n))))))
    (is (not (apfs::fits-p records t t 16 16)))
    (is (= 3 (length nodes)))
    (is (= 112 (loop :for (nil level . node) :in nodes :when (zerop level) :sum (apfs::node-count (apfs::make-node node)))))))
