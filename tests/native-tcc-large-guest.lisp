(in-package #:cl-user)
(defun tcc-large-check (label ok)
  (format t "~&[NATIVE-TCC ~a ~a]~%" label (if ok "PASS" "FAIL"))
  (finish-output))
(multiple-value-bind (compiler support)
    (darterfly/cc:build-native-tcc "/tmp/tcc-large")
  (with-open-file (s "/tmp/large.c" :direction :output)
    (write-line "unsigned char data[1048609] = {[0]=17, [1048608]=29};" s)
    (write-line "int main(void) { return data[0]==17 && data[100]==0 && data[1048608]==29 ? 41 : 1; }" s))
  (tcc-large-check "LARGE-COMPILE"
    (and (darterfly/cc:compile-native-c compiler "/tmp/large.c" "/tmp/large.o"
                                       :compat nil)
         (with-open-file (s "/tmp/large.o" :element-type '(unsigned-byte 8))
           (> (file-length s) 1048609))))
  (darterfly/cc:link-native-program "/tmp/large" (cons "/tmp/large.o" support))
  (let ((p (sb-ext:run-program "/tmp/large" nil :search nil)))
    (unwind-protect
         (tcc-large-check "LARGE-RUN"
           (and (eq :exited (sb-ext:process-status p))
                (= 41 (sb-ext:process-exit-code p))))
      (sb-ext:process-close p)))
  (with-open-file (s "/tmp/stdio-error.c" :direction :output)
    (write-line "#include <stdio.h>" s)
    (write-line "#include <errno.h>" s)
    (write-line "#include <stdint.h>" s)
    (write-line "int main(void) { FILE *f=fopen(\"/tmp/large.c\",\"r\"); int ok; if(!f) return 1; ok=fwrite(\"x\",1,1,f)==0 && ferror(f) && errno==EBADF; clearerr(f); ok=ok && fwrite(\"x\",(size_t)-1,2,f)==0 && ferror(f) && errno==EINVAL; fclose(f); return ok ? 0 : 2; }" s))
  (assert (darterfly/cc:compile-native-c compiler "/tmp/stdio-error.c"
                                        "/tmp/stdio-error.o" :compat nil))
  (darterfly/cc:link-native-program "/tmp/stdio-error"
                                    (cons "/tmp/stdio-error.o" support))
  (let ((p (sb-ext:run-program "/tmp/stdio-error" nil :search nil)))
    (unwind-protect
         (tcc-large-check "STDIO-ERROR" (eql 0 (sb-ext:process-exit-code p)))
      (sb-ext:process-close p))))
