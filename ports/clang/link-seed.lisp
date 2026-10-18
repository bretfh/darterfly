(require :asdf)
(asdf:load-system :darterfly/cc)
(let ((root (asdf:system-source-directory :darterfly)))
  (darterfly/cc:link-native-program
   (merge-pathnames "build/clang/clang" root)
   (loop for name in '("build/clang/bin/darter-clang.o"
                      "build/cxx/runtime.o" "build/cxx/crt0.o")
         collect (namestring (merge-pathnames name root)))))
;; Keep a symbol map for native-world fault diagnostics (the ELF is stripped).
(let* ((root (asdf:system-source-directory :darterfly))
       (objects (cons (darterfly/link:read-object (darterfly/libsa:libsa-object)
                                                  "libsa.o" :user)
                      (loop for name in '("build/clang/bin/darter-clang.o"
                                          "build/cxx/runtime.o" "build/cxx/crt0.o")
                            collect (darterfly/cc::native-object (merge-pathnames name root))))))
  (darterfly/link::lay-out :user #x400000 objects)
  (with-open-file (s (merge-pathnames "build/clang/clang.map" root)
                     :direction :output :if-exists :supersede)
    (dolist (object objects)
      (loop for sym across (darterfly/link::object-symbols object)
            when (and (darterfly/link::section-p (darterfly/link::sym-section sym))
                      (plusp (length (darterfly/link::sym-name sym)))) do
              (format s "~x ~a~%"
                      (+ (darterfly/link::section-address (darterfly/link::sym-section sym))
                         (darterfly/link::sym-value sym))
                      (darterfly/link::sym-name sym))))))
