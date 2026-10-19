(in-package #:darterfly/test)
(def-suite native-clang :in host)
(in-suite native-clang)

(defun extended-index-object ()
  ;; Small ELF fixture using the large-object escape encodings. Section 4
  ;; serves as both string tables; section 3 is SHT_SYMTAB_SHNDX for section 2.
  (let* ((v (make-array 600 :element-type '(unsigned-byte 8) :initial-element 0))
         (names (format nil "~c.text~c.symtab~c.indices~c.strtab~centry~c"
                        #\Null #\Null #\Null #\Null #\Null #\Null)))
    (flet ((put (at value size) (darterfly/link::put v at value size)))
      (replace v #(127 69 76 70 2 1 1))
      (put 16 1 2) (put 18 62 2) (put 20 1 4)
      (put 40 64 8) (put 52 64 2) (put 58 64 2)
      (put 60 0 2) (put 62 #xFFFF 2)
      (put (+ 64 32) 5 8) (put (+ 64 40) 4 4)
      (loop for i from 1 to 4
            for name in '(".text" ".symtab" ".indices" ".strtab")
            for type in '(1 2 18 3)
            for offset in '(384 416 464 480)
            for size in (list 1 48 8 (length names))
            for h = (+ 64 (* i 64)) do
              (put h (search name names) 4)
              (put (+ h 4) type 4) (put (+ h 24) offset 8)
              (put (+ h 32) size 8) (put (+ h 48) 1 8))
      (put (+ 128 8) 6 8) ; alloc + executable
      (put (+ 192 40) 4 4) (put (+ 192 56) 24 8)
      (put (+ 256 40) 2 4) (put (+ 256 56) 4 8)
      (put 384 #xC3 1)
      (put 440 (search "entry" names) 4) (put 444 #x12 1)
      (put 446 #xFFFF 2) (put 468 1 4)
      (replace v (map '(vector (unsigned-byte 8)) #'char-code names) :start1 480))
    v))

(test extended-elf-section-indices
  (let* ((bytes (extended-index-object))
         (o (darterfly/link:read-object bytes "extended.o" :user))
         (sym (aref (darterfly/link::object-symbols o) 1))
         (section (first (darterfly/link::object-sections o))))
    (is (string= "entry" (darterfly/link::sym-name sym)))
    (is (eq section (darterfly/link::sym-section sym)))
    (is (equalp #(195) (darterfly/link::section-data section)))
    (is (plusp (length (darterfly/link:link-native (list o) :entry "entry"))))
    (darterfly/link::put bytes (+ 256 32) 5 8)
    (signals error (darterfly/link:read-object bytes "short-indices.o" :user))
    (darterfly/link::put bytes (+ 256 32) 8 8)
    (darterfly/link::put bytes (+ 256 4) 0 4)
    (signals error (darterfly/link:read-object bytes "missing-indices.o" :user))))

(in-suite guest)

(test native-clang-on-darterfly
  ;; Seed creation is separate and recorded. Never fall back to a host compile
  ;; when the guest frontend fails.
  (let* ((dir (scratch)) (disk (merge-pathnames "native-clang.img" dir))
         (llvm #P"/gnu/store/9s6ip95sbxhfqx63c2nd7lz9xgl701kr-llvm-project-19.1.7-checkout/"))
    (unless (probe-file (darterfly-file "build/clang/clang"))
      (error "Build the native Clang seed first: tools/build-native-clang.py"))
    (image::root-disk
     disk (* 1024 1048576)
     (append
      (image::root-entries)
      (image::tree-entries (darterfly-file "build/cxx/include/c++/v1/")
                           "usr/include/c++/v1")
      (image::tree-entries (darterfly-file "build/clang/lib/clang/19/include/")
                           "usr/lib/clang/19/include")
      (image::tree-entries (merge-pathnames "llvm/include/llvm/Demangle/" llvm)
                           "usr/src/llvm/include/llvm/Demangle")
      (list (list :dir "usr/bin")
            (list :dir "usr/src/llvm/lib")
            (list :file "usr/src/llvm/lib/ItaniumDemangle.cpp"
                  (image::octets (merge-pathnames "llvm/lib/Demangle/ItaniumDemangle.cpp" llvm)))
            (list :file "usr/bin/clang" (image::octets
                          (darterfly-file "build/clang/clang")) #o755)
            (list :dir "usr/lib/cxx")
            (list :file "usr/lib/cxx/runtime.o" (image::octets
                          (darterfly-file "build/cxx/runtime.o"))))
      (loop for name in '("native-clang-guest.lisp" "native-clang-probe.cpp" "native-clang-demangle.cpp")
            collect (list :file (concatenate 'string "Users/darterfly/" name)
                          (image::octets (darterfly-file
                                          (concatenate 'string "tests/" name)))))))
    (let* ((image::*console-log-directory* (merge-pathnames "native-clang-console/" dir))
           (c (image:bare-console :root disk)))
      (unwind-protect
           (progn
             (image:expect c "* " :timeout 180)
             (image:send c "(progn (load \"/Users/darterfly/native-clang-guest.lisp\") (format t \"~%[CLANG DONE]~%\"))")
             (let ((output (image:expect c '("[CLANG DONE]" "debugger invoked")
                                         :timeout 900)))
               (when (search "debugger invoked" output)
                 (setf output (concatenate 'string output
                                          (image:expect c "0] " :timeout 10))))
               (with-open-file (s (merge-pathnames "native-clang-guest.log" image:*build*)
                                  :direction :output :if-exists :supersede)
                 (write-string output s))
               (dolist (label '("VERSION" "COMPILE" "OBJECT" "CXX-PROGRAM" "RUN"
                                "DIAGNOSTIC" "RECOMPILE" "CHANGED-PROGRAM" "LLVM-COMPILE"
                                "LLVM-DRIVER" "LLVM-COMPONENT" "LLVM-RUN" "CLEAN"))
                 (is (search (format nil "[CLANG ~a PASS]" label) output)
                     "Native Clang check ~a: ~a" label output))))
        (image:finish c 5)))))
