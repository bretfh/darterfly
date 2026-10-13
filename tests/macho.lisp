(in-package #:finch/test)

(def-suite macho :in all)
(in-suite macho)

(defparameter +source+ "
int counter = 3;
static int hidden(int x) { return x * 2; }
int finch_add(int a, int b) { return hidden(a) + b + counter; }
")

(defparameter +user+ "
extern int finch_add(int, int);
int finch_twice(int a) { return finch_add(a, a); }
")

(defvar *images* nil)

(defun images ()
  (or *images*
      (let ((dir (scratch)))
        (flet ((path (name) (uiop:native-namestring (merge-pathnames name dir))))
          (with-open-file (s (path "a.c") :direction :output :if-exists :supersede)
            (write-string +source+ s))
          (with-open-file (s (path "b.c") :direction :output :if-exists :supersede)
            (write-string +user+ s))
          (sh "clang" "-target" "x86_64-apple-macos15" "-c" (path "a.c") "-o" (path "a.o"))
          (sh "clang" "-target" "arm64-apple-macos15" "-c" (path "a.c") "-o" (path "arm.o"))
          (sh "clang" "-target" "x86_64-apple-macos15" "-c" (path "b.c") "-o" (path "b.o"))
          (sh "ld64.lld" "-dylib" "-arch" "x86_64" "-platform_version" "macos" "15.0" "15.0"
              "-install_name" "/usr/lib/libfinch.dylib" "-current_version" "1.2.3"
              "-o" (path "libfinch.dylib") (path "a.o"))
          (sh "ld64.lld" "-dylib" "-arch" "x86_64" "-platform_version" "macos" "15.0" "15.0"
              "-install_name" "/usr/lib/libuser.dylib" "-rpath" "@loader_path/../lib"
              "-o" (path "libuser.dylib") (path "b.o") (path "libfinch.dylib"))
          (sh "llvm-lipo" "-create" (path "a.o") (path "arm.o") "-output" (path "fat.o")))
        (setf *images* dir))))

(defun image-path (name)
  (uiop:native-namestring (merge-pathnames name (images))))

(defun objdump-lines (name pattern)
  (let ((scanner (format nil "^\\s*(~a) (\\S+)" pattern)))
    (loop :for line :in (uiop:split-string (sh "llvm-objdump" "--macho" "--private-headers"
                                               (image-path name))
                                           :separator '(#\Newline))
          :for words := (remove "" (uiop:split-string (string-trim " " line)) :test #'string=)
          :when (and (= 2 (min 2 (length words)))
                     (member (first words) (uiop:split-string pattern :separator "|")
                             :test #'string=))
            :collect (list (first words) (second words)))))

(defun lc-name (kind)
  (substitute #\_ #\- (symbol-name kind)))

(defun same-commands (name)
  (let ((image (macho:read-macho (image-path name))))
    (is (equal (mapcar #'second (objdump-lines name "cmd"))
               (mapcar (lambda (c) (lc-name (macho:command-kind c))) (macho:image-commands image))))
    (is (equal (objdump-lines name "segname|sectname")
               (loop :for s :in (macho:segments image)
                     :unless (string= "" (macho:segment-name s))
                       :collect (list "segname" (macho:segment-name s))
                     :append (loop :for x :in (macho:segment-sections s)
                                   :collect (list "sectname" (macho:section-name x))
                                   :collect (list "segname" (macho:section-segment-name x))))))
    (is (equal (loop :for line :in (uiop:split-string (sh "llvm-nm" "-p" "-a" (image-path name))
                                                      :separator '(#\Newline))
                     :for words := (remove "" (uiop:split-string line) :test #'string=)
                     :when words :collect (car (last words)))
               (mapcar #'macho:nlist-name (macho:symbols image))))
    image))

(test object
  (let ((image (same-commands "a.o")))
    (is (eq :x86-64 (macho:image-cputype image)))
    (is (eq :mh-object (macho:image-filetype image)))
    (is (= 64 (macho:image-bits image)))))

(test dylib
  (let ((image (same-commands "libfinch.dylib")))
    (is (eq :mh-dylib (macho:image-filetype image)))
    (is (string= "/usr/lib/libfinch.dylib" (macho:install-name image)))
    (is (string= "1.2.3" (macho:version-string
                          (macho:dylib-current-version (macho:find-command image :lc-id-dylib)))))
    (is (string= (second (first (objdump-lines "libfinch.dylib" "uuid")))
                 (macho:uuid (macho:find-command image :lc-uuid))))
    (is (string= "15.0.0" (macho:version-string
                           (macho:build-minos (macho:find-command image :lc-build-version)))))))

(test dependent-dylib
  (let ((image (same-commands "libuser.dylib")))
    (is (equal '("/usr/lib/libfinch.dylib") (macho:dylibs image)))
    (is (string= "@loader_path/../lib"
                 (macho:command-path (macho:find-command image :lc-rpath))))))

(test fat
  (let ((fat (macho:read-macho (image-path "fat.o"))))
    (is (typep fat 'macho:fat))
    (is (equal (remove "" (uiop:split-string (string-trim '(#\Newline #\Space)
                                                          (sh "llvm-lipo" "-archs" (image-path "fat.o"))))
                       :test #'string=)
               (mapcar (lambda (s) (substitute #\_ #\- (string-downcase (macho:slice-cputype s))))
                       (macho:fat-slices fat))))
    (dolist (s (macho:fat-slices fat))
      (is (equal '("_counter" "_finch_add")
                 (sort (loop :for n :in (macho:symbols (macho:slice-image s))
                             :when (logbitp 0 (macho:nlist-type n))
                               :collect (macho:nlist-name n))
                       #'string<))))))

(test not-macho
  (signals macho:macho-error
    (macho:read-macho (make-array 64 :element-type '(unsigned-byte 8) :initial-element 0))))
