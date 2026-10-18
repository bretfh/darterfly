(in-package #:darterfly/test)
(def-suite native-cxx :in host)
(in-suite native-cxx)

(test runtime-array-boundaries-and-priorities
  (let* ((data (darterfly/link::make-section :name ".data" :kind :data
                                            :size 3 :alignment 1))
         (late (darterfly/link::make-section :name ".init_array" :kind :init-array
                                            :size 8 :alignment 8))
         (early (darterfly/link::make-section :name ".init_array.101" :kind :init-array
                                             :size 8 :alignment 8))
         (object (darterfly/link::make-object :sections (list data late early)))
         (image (darterfly/link::lay-out :user #x400000 (list object)))
         (globals (make-hash-table :test 'equal)))
    (darterfly/link::define-runtime-symbols globals image)
    (is (= 0 (mod (gethash "__init_array_start" globals) 8)))
    (is (= (gethash "__init_array_start" globals) (darterfly/link::section-address early)))
    (is (= (+ 8 (darterfly/link::section-address early)) (darterfly/link::section-address late)))
    (is (= (+ 8 (darterfly/link::section-address late)) (gethash "__init_array_end" globals)))
    (is (= 0 (gethash "__eh_frame_hdr_start" globals)))))

(test noop-relocation-does-not-resolve-null-symbol
  (let* ((data (make-array 8 :element-type '(unsigned-byte 8) :initial-element 91))
         (section (darterfly/link::make-section :name ".eh_frame" :kind :eh-frame
                    :data data :size 8 :alignment 8
                    :relocations (list (list 0 (darterfly/link::make-sym
                                                  :name "" :section :undefined) 0 22))))
         (object (darterfly/link::make-object :sections (list section)))
         (image (darterfly/link::lay-out :user #x400000 (list object))))
    (darterfly/link::relocate image (make-hash-table :test 'equal) image)
    (is (equalp data (darterfly/link::section-data section)))
    (is (eq :eh-frame (darterfly/link::classify ".eh_frame" #x70000001 2)))))

(in-suite guest)

(test native-cxx-runtime-on-darterfly
  (sh "python3" (namestring (darterfly-file "tools/build-cxx-runtime.py")) "--probe")
  ;; Fail unresolved-runtime symbols before the expensive OS boot.
  (let* ((dir (scratch)) (disk (merge-pathnames "native-cxx.img" dir))
         (objects (loop for name in '("runtime.o" "probe.o" "crt0.o")
                        collect (namestring (darterfly-file
                                             (concatenate 'string "build/cxx/" name))))))
    (darterfly/cc:link-native-program (merge-pathnames "cxx" dir) objects)
    (image::root-disk
     disk (* 512 1048576)
     (append (image::root-entries)
             (loop for object in objects
                   collect (list :file (concatenate 'string "Users/darterfly/"
                                                   (file-namestring object))
                                 (image::octets object)))
             (list (list :file "Users/darterfly/native-cxx-guest.lisp"
                         (image::octets (darterfly-file "tests/native-cxx-guest.lisp"))))))
    (let* ((image::*console-log-directory* (merge-pathnames "native-cxx-console/" dir))
           (c (image:bare-console :root disk)))
      (unwind-protect
           (progn
             (image:expect c "* " :timeout 120)
             (image:send c "(progn (load \"/Users/darterfly/native-cxx-guest.lisp\") (format t \"~%[CXX DONE]~%\"))")
             (let ((output (image:expect c '("[CXX DONE]" "debugger invoked") :timeout 300)))
               (when (search "debugger invoked" output)
                 (setf output (concatenate 'string output (image:expect c "0] " :timeout 10))))
               (with-open-file (s (merge-pathnames "native-cxx-guest.log" image:*build*)
                                  :direction :output :if-exists :supersede)
                 (write-string output s))
               (dolist (label '("CONSTRUCTORS" "STL-ALLOCATION" "ALLOCATION-FAILURE" "RTTI" "EXCEPTIONS"
                                "GUARD-RETRY" "THREADS-TLS-GUARDS" "KEY-DESTRUCTORS"
                                "FINALIZE" "CLOCK" "EXIT" "DESTRUCTION" "TERMINATE"
                                "REPEAT" "ISOLATION" "CLEAN"))
                 (is (search (format nil "[CXX ~a PASS]" label) output)
                     "C++ runtime check ~a: ~a" label output))))
        (image:finish c 5)))))
