(require :asdf)
(asdf:load-system :darterfly/cc)
(defparameter *native-tool* (or (uiop:getenv "DARTERFLY_NATIVE_TOOL") "clang"))
(assert (member *native-tool* '("clang" "lld") :test #'string=))
(defparameter *native-output*
  (if (string= *native-tool* "lld") "build/lld/ld.lld" "build/clang/clang"))
(defparameter *native-inputs*
  (list (format nil "build/clang/bin/darter-~a.o" *native-tool*)
        "build/cxx/runtime.o" "build/cxx/crt0.o"))
(let ((root (asdf:system-source-directory :darterfly)))
  (darterfly/cc:link-native-program
   (merge-pathnames *native-output* root)
   (loop for name in *native-inputs*
         collect (namestring (merge-pathnames name root)))))
;; Keep a symbol map for native-world fault diagnostics (the ELF is stripped).
(let* ((root (asdf:system-source-directory :darterfly))
       (objects (cons (darterfly/link:read-object (darterfly/libsa:libsa-object)
                                                  "libsa.o" :user)
                      (loop for name in *native-inputs*
                            collect (darterfly/cc::native-object (merge-pathnames name root))))))
  (darterfly/link::lay-out :user #x400000 objects)
  (with-open-file (s (merge-pathnames (concatenate 'string *native-output* ".map") root)
                     :direction :output :if-exists :supersede)
    (dolist (object objects)
      (loop for sym across (darterfly/link::object-symbols object)
            when (and (darterfly/link::section-p (darterfly/link::sym-section sym))
                      (plusp (length (darterfly/link::sym-name sym)))) do
              (format s "~x ~a~%"
                      (+ (darterfly/link::section-address (darterfly/link::sym-section sym))
                         (darterfly/link::sym-value sym))
                      (darterfly/link::sym-name sym))))))
