(in-package #:finch/test)

(def-suite apfs :in all)
(in-suite apfs)

(defun apfs-volume ()
  (let* ((disk (gunzip-fixture "apfs-disk.img.gz" "apfs-host.img"))
         (part (find "7C3457EF-0000-11AA-AA11-00306543ECAC" (ioreg-media (finch-file "tests/media.txt"))
                     :test #'equal :key (lambda (m) (cdr (assoc "Content" (third m) :test #'string=)))))
         (base (cdr (assoc "Base" (third part) :test #'string=))))
    (first (apfs:container-volumes (apfs:open-container (apfs:file-device disk :offset base))))))

(defun file-type-bits (name)
  (cdr (assoc name '(("Directory" . #o040000) ("Regular File" . #o100000) ("Symbolic Link" . #o120000))
              :test #'string=)))

(test container-and-volume
  (let ((v (apfs-volume)))
    (is (equal "finch" (apfs:volume-name v)))
    (is (apfs:volume-case-insensitive-p v))
    (is (null (apfs:lookup v "/not/there")))))

(test files-match-tahoe
  (let ((v (apfs-volume)))
    (dolist (line (uiop:read-file-lines (finch-file "tests/apfs-files.txt")))
      (destructuring-bind (path type perms size ino nlink uid gid target md5)
          (uiop:split-string line :separator "|")
        (let ((id (apfs:lookup v path)))
          (is (eql (parse-integer ino) id) "~a: inode ~a, finch ~a" path ino id)
          (when id
            (let* ((i (apfs:inode v id))
                   (dir (string= type "Directory"))
                   (links (if dir (+ 2 (apfs:inode-nlink i)) (apfs:inode-nlink i))))
              (is (= (file-type-bits type) (logand (apfs:inode-mode i) #o170000)) "~a: type" path)
              (is (= (parse-integer perms :radix 8) (logand (apfs:inode-mode i) #o7777)) "~a: mode" path)
              (is (= (parse-integer nlink) links) "~a: links" path)
              (is (= (parse-integer uid) (apfs:inode-owner i)) "~a: owner" path)
              (is (= (parse-integer gid) (apfs:inode-group i)) "~a: group" path)
              (is (= (parse-integer size)
                     (cond (dir (* 32 links))
                           ((string= type "Symbolic Link") (length (sb-ext:string-to-octets (apfs:readlink v id) :external-format :utf-8)))
                           (t (apfs:inode-size i))))
                  "~a: size" path)
              (when (string= type "Symbolic Link")
                (is (equal target (apfs:readlink v id))))
              (unless (string= md5 "-")
                (is (equal md5 (string-downcase (format nil "~{~2,'0x~}" (coerce (sb-md5:md5sum-sequence (apfs:read-file v id)) 'list))))
                    "~a: contents" path)))))))))

(test directories-list
  (let* ((v (apfs-volume))
         (many (apfs:directory-entries v (apfs:lookup v "/many"))))
    (is (= 300 (length many)))
    (is (equal "file 7" (string-right-trim '(#\Newline) (map 'string #'code-char (apfs:read-file v (apfs:lookup v "/many/f7"))))))
    (is (equal "line 12345 of a" (map 'string #'code-char (apfs:read-file v (apfs:lookup v "/big.txt") :start (* 12345 47) :end (+ (* 12345 47) 15)))))))

(defun image-md5 (path)
  (with-open-file (s path :element-type '(unsigned-byte 8))
    (string-downcase (format nil "~{~2,'0x~}" (coerce (sb-md5:md5sum-stream s) 'list)))))

(defun newfs-image ()
  (apfs:newfs (merge-pathnames "newfs.img" (finch-file "build/")) :volume-name "finch"))

(defun record-newfs ()
  (let* ((image (newfs-image))
         (verdict (tahoe:apfs-check image)))
    (with-open-file (s (finch-file "tests/apfs-newfs.txt") :direction :output :if-exists :supersede)
      (format s "md5 ~a~%~a" (image-md5 image) verdict))
    verdict))

(test newfs-was-judged-by-tahoe
  (let* ((lines (uiop:read-file-lines (finch-file "tests/apfs-newfs.txt")))
         (image (newfs-image)))
    (is (equal (first lines) (format nil "md5 ~a" (image-md5 image))))
    (is (find "** The container /dev/disk7 appears to be OK." lines :test #'search))
    (is (find ".|Directory|755|64|2|2|501|20||-" lines :test #'string=))
    (let ((v (first (apfs:container-volumes (apfs:open-container (apfs:file-device image))))))
      (is (equal "finch" (apfs:volume-name v)))
      (is (= 2 (apfs:lookup v "/"))))))
