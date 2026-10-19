(in-package #:darterfly/cc)

(defun compile-native-c (compiler source object &key includes defines (compat t)
                            directory (output *standard-output*) (error *error-output*)
                            (tcc-dir "/usr/lib/tcc/")
                            (libsa-dir "/usr/src/darterfly/src/libsa/"))
  "Run the upstream TCC CLI as a BSD native process. Return success and status."
  (setf object (namestring (merge-pathnames object
                            (uiop:ensure-directory-pathname
                             (merge-pathnames (or directory (uiop:getcwd))
                                              (uiop:getcwd))))))
  (uiop:delete-file-if-exists object)
  (let* ((args (append (arguments source :includes includes :defines defines
                                 :compat compat :tcc-dir tcc-dir :libsa-dir libsa-dir)
                       (list "-c" source "-o" object)))
         (process (sb-ext:run-program compiler args :search nil :wait t
                                      :directory directory :output output :error error)))
    (unwind-protect
         (let ((status (sb-ext:process-exit-code process)))
           (unless (and (eq (sb-ext:process-status process) :exited) (eql status 0))
             (uiop:delete-file-if-exists object)
             (return-from compile-native-c (values nil status)))
           (values t status))
      (sb-ext:process-close process))))

(defun native-object (path)
  (with-open-file (s path :element-type '(unsigned-byte 8))
    (let ((bytes (make-array (file-length s) :element-type '(unsigned-byte 8))))
      (read-sequence bytes s)
      (darterfly/link:read-object bytes (namestring (pathname path)) :user))))

(defun link-native-program (output objects &key map-file)
  "Link CRT0 and C objects with the shared libsa; optionally record symbols."
  (multiple-value-bind (elf globals)
      (darterfly/link:link-native
       (cons (darterfly/link:read-object (darterfly/libsa:libsa-object)
                                        "libsa.o" :user)
             (mapcar #'native-object objects)))
    (ensure-directories-exist output)
    (with-open-file (s output :direction :output :if-exists :supersede
                             :element-type '(unsigned-byte 8))
      (write-sequence elf s))
    (sb-posix:chmod output #o755)
    (when map-file
      (ensure-directories-exist map-file)
      (with-open-file (s map-file :direction :output :if-exists :supersede)
        (dolist (entry (sort (loop for name being the hash-keys of globals
                                   using (hash-value address)
                                 collect (cons address name)) #'< :key #'car))
          (format s "~16,'0x ~a~%" (car entry) (cdr entry)))))
    output))

(defun build-native-tcc (output &key compiler verbose
                          (tcc-dir "/usr/lib/tcc/")
                          (directory "/usr/src/darterfly/")
                          (work "/tmp/native-tcc-build/"))
  "Seed with embedded TCC, or build using standalone COMPILER.
On Darterfly the compiler runs in its own world. Host packaging can use the
pinned host TCC. The upstream driver is unchanged; Lisp links shared libsa."
  (let* ((root (uiop:ensure-directory-pathname directory))
         (work (uiop:ensure-directory-pathname work))
         (tree (namestring (merge-pathnames "build/tcc/darterfly-src/" root)))
         (crt (namestring (merge-pathnames "crt0.o" work)))
         (tcc (namestring (merge-pathnames "tcc.o" work)))
         (support (loop for source in *libtcc1-sources*
                        collect (namestring
                                 (merge-pathnames
                                  (format nil "support/~a.o" (pathname-name source))
                                  work)))))
    (ensure-directories-exist crt)
    (flet ((compile-one (source object &rest options)
             (when verbose
               (format t "~&TCC [~a]: ~a~%" (or compiler :embedded) source)
               (finish-output))
             (setf options (append options
                                   (list :tcc-dir tcc-dir :libsa-dir (namestring
                                         (merge-pathnames "src/libsa/" root)))))
             (unless (if compiler
                         (apply #'compile-native-c compiler source object options)
                         (apply #'compile-c source object options))
               (error "TCC failed to compile ~a" source))))
      (compile-one (namestring (merge-pathnames "src/libsa/crt0.S" root))
                   crt :compat nil)
      (compile-one (concatenate 'string tree "tcc.c") tcc
                   :includes (list tree)
                   :defines '("ONE_SOURCE=1" "TCC_TARGET_X86_64=1"
                              "CONFIG_TCC_BACKTRACE=0" "CONFIG_TCC_BCHECK=0"))
      ;; These are the pinned compiler's arithmetic/varargs/atomic helpers,
      ;; already used by Darterfly's TCC-built runtime, not another libc.
      (loop for source in *libtcc1-sources* for object in support do
        (ensure-directories-exist object)
        (compile-one (namestring (merge-pathnames
                                 (concatenate 'string "build/tcc/stage2/lib/" source)
                                 root)) object :compat nil)))
    (values (link-native-program output (append (list crt tcc) support))
            (cons crt support))))

(defun compile-native-cxx (compiler source object &key includes defines directory
                              (output *standard-output*) (error *error-output*)
                              pic (exceptions t) (standard "c++20")
                              (cxx-include "/usr/include/c++/v1")
                              (libsa-include "/usr/src/darterfly/src/libsa/include")
                              (resource-dir "/usr/lib/clang/19"))
  "Run upstream Clang's cc1 frontend in a native world, producing an ELF object.
The compiler is a recorded cross seed; compiling SOURCE happens in Darterfly.
PIC selects general-dynamic TLS for shared objects. EXCEPTIONS defaults to T."
  (setf object (namestring (merge-pathnames object
                            (uiop:ensure-directory-pathname
                             (merge-pathnames (or directory (uiop:getcwd))
                                              (uiop:getcwd))))))
  (uiop:delete-file-if-exists object)
  (let* ((args (append
                (list "-cc1" "-triple" "x86_64-unknown-none-elf"
                      "-emit-obj" "-x" "c++" (concatenate 'string "-std=" standard)
                      "-mrelocation-model" (if pic "pic" "static") "-disable-red-zone"
                      (if pic "-ftls-model=global-dynamic" "-ftls-model=local-exec")
                      "-D__darterfly__" "-nostdsysteminc"
                      "-resource-dir" resource-dir
                      "-internal-isystem" cxx-include
                      "-internal-isystem" libsa-include
                      "-internal-isystem" (concatenate 'string resource-dir "/include"))
                (when pic (list "-pic-level" "2"))
                (when exceptions (list "-fcxx-exceptions" "-fexceptions"))
                (loop for i in includes append (list "-I" i))
                (loop for d in defines collect (concatenate 'string "-D" d))
                (list source "-o" object)))
         (process (sb-ext:run-program compiler args :search nil :wait t
                                      :directory directory :output output :error error)))
    (unwind-protect
         (let ((status (sb-ext:process-exit-code process)))
           (unless (and (eq (sb-ext:process-status process) :exited) (eql status 0)
                        (probe-file object))
             (uiop:delete-file-if-exists object)
             (return-from compile-native-cxx (values nil status)))
           (values t status))
      (sb-ext:process-close process))))

(defun link-native-cxx (linker executable objects &key directory
                            (output *standard-output*) (error *error-output*)
                            (script "/usr/src/darterfly/ports/lld/native.ld")
                            relocatable shared soname (hash-style "both"))
  "Run upstream ELF LLD in a world. Final links regenerate shared Low libsa.
OBJECTS includes CRT0 and the C++ runtime for an executable. Partial and
SHARED links inject neither CRT nor libsa. Shared libraries import the existing
process runtime and use sibling dependencies through $ORIGIN."
  (when (and relocatable shared) (error "Choose either a partial or shared link"))
  (setf executable (namestring (merge-pathnames executable
                                (uiop:ensure-directory-pathname
                                 (merge-pathnames (or directory (uiop:getcwd))
                                                  (uiop:getcwd))))))
  (let ((runtime (concatenate 'string executable ".libsa.o"))
        (response (concatenate 'string executable ".rsp")))
    (uiop:delete-file-if-exists executable)
    (unwind-protect
         (progn
           (unless (or relocatable shared)
             (with-open-file (s runtime :direction :output :if-exists :supersede
                                        :element-type '(unsigned-byte 8))
               (write-sequence (darterfly/libsa:libsa-object) s)))
           (let* ((args (append
                         '("-m" "elf_x86_64" "--threads=1" "--no-mmap-output-file")
                         (cond (relocatable '("-r"))
                               (shared
                                (append
                                 (list "-shared" "--build-id=none"
                                       (concatenate 'string "--hash-style=" hash-style)
                                       "-z" "now" "-z" "relro" "-z" "separate-code"
                                       "-z" "noexecstack" "-rpath" "$ORIGIN")
                                 (when soname (list "-soname" soname))))
                               (t (list "-static" "--no-dynamic-linker" "--build-id=none"
                                        "-z" "noexecstack" "-T" script runtime)))
                         objects (list "-o" executable)))
                  ;; LLVM's own response parser avoids the world's argv limit.
                  (process
                    (progn
                      (with-open-file (s response :direction :output :if-exists :supersede)
                        (dolist (arg args)
                          (write-char #\" s)
                          (loop for c across arg do
                            (when (find c '(#\" #\\)) (write-char #\\ s))
                            (write-char c s))
                          (write-char #\" s) (terpri s)))
                      (sb-ext:run-program linker (list (concatenate 'string "@" response))
                                          :search nil :wait t :directory directory
                                          :output output :error error))))
             (unwind-protect
                  (let ((status (sb-ext:process-exit-code process)))
                    (unless (and (eq :exited (sb-ext:process-status process))
                                 (eql status 0) (probe-file executable))
                      (uiop:delete-file-if-exists executable)
                      (return-from link-native-cxx (values nil status)))
                    (unless (or relocatable shared) (sb-posix:chmod executable #o755))
                    (values t status))
               (sb-ext:process-close process))))
      (uiop:delete-file-if-exists response)
      (unless (or relocatable shared) (uiop:delete-file-if-exists runtime)))))
