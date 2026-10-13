(in-package #:finch/test)

(def-suite dyld :in all)
(in-suite dyld)

(defparameter *tahoe*
  (or (uiop:getenv "FINCH_TAHOE_DYLD")
      (uiop:native-namestring "~/vm/tahoe/dyld/dyld_shared_cache_x86_64h")))

(defvar *cache* nil)

(defun cache ()
  (or *cache* (setf *cache* (dyld:open-cache *tahoe*))))

(defun hex (text)
  (parse-integer text :start 2 :radix 16))

(defun read-map ()
  (let ((mappings nil) (images nil))
    (with-open-file (in (concatenate 'string *tahoe* ".map"))
      (loop :for line := (read-line in nil)
            :while line
            :for words := (remove "" (uiop:split-string line :separator '(#\Space #\Tab))
                                  :test #'string=)
            :do (cond ((and words (string= (first words) "mapping"))
                       (push (list (hex (nth 3 words)) (hex (nth 5 words))) mappings))
                      ((and (plusp (length line)) (char= (char line 0) #\/))
                       (push (list line) images))
                      ((and images words (char= (char line 0) #\Tab))
                       (push (list (first words) (hex (second words))) (rest (first images)))))))
    (values (reverse mappings)
            (mapcar (lambda (i) (cons (first i) (reverse (rest i)))) (reverse images)))))

(defmacro with-tahoe (&body body)
  `(if (probe-file *tahoe*)
       (progn ,@body)
       (skip "no Tahoe cache at ~a" *tahoe*)))

(test tahoe-header
  (with-tahoe
    (let ((c (cache)))
      (is (string= "x86_64h" (dyld:cache-architecture c)))
      (is (string= "31374756-89B4-34E8-A34F-56C5D57216A1" (dyld:cache-uuid c)))
      (is (= 1 (dyld:cache-platform c)))
      (is (equal '("" ".01" ".02" ".03" ".04" ".05" ".06")
                 (mapcar #'dyld:file-suffix (dyld:cache-files c)))))))

(test tahoe-mappings-match-the-map
  (with-tahoe
    (is (equal (read-map)
               (loop :for f :in (dyld:cache-files (cache))
                     :append (loop :for m :in (dyld:file-mappings f)
                                   :collect (list (dyld:mapping-address m)
                                                  (+ (dyld:mapping-address m)
                                                     (dyld:mapping-size m)))))))))

(test tahoe-images-match-the-map
  (with-tahoe
    (let ((images (nth-value 1 (read-map)))
          (c (cache)))
      (is (= (length images) (length (dyld:cache-images c))))
      (is (equal (mapcar #'first images) (mapcar #'dyld:image-path (dyld:cache-images c))))
      (let ((wrong (loop :for (path . segments) :in images
                         :for image := (dyld:find-image c path)
                         :unless (and image
                                      (= (dyld:image-address image) (second (first segments)))
                                      (equal segments
                                             (loop :for s :in (macho:segments (dyld:image-macho c image))
                                                   :unless (member (macho:segment-name s)
                                                                   '("__OBJC_RO" "__OBJC_RW")
                                                                   :test #'string=)
                                                   :collect (list (macho:segment-name s)
                                                                  (macho:segment-vmaddr s)))))
                           :collect path)))
        (is (null wrong) "~d of ~d images differ from the map, first ~a"
            (length wrong) (length images) (first wrong))))))

(test tahoe-appkit
  (with-tahoe
    (let ((appkit (dyld:image-macho (cache) "/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit")))
      (is (eq :x86-64 (macho:image-cputype appkit)))
      (is (eq :mh-dylib (macho:image-filetype appkit)))
      (is (string= "/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit"
                   (macho:install-name appkit)))
      (is (member "/System/Library/Frameworks/Foundation.framework/Versions/C/Foundation"
                  (macho:dylibs appkit) :test #'string=)))))
