(in-package #:finch/test)

(def-suite mig :in all)
(in-suite mig)

(defparameter +skylight+ "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight")

(defun nm-text (file)
  (let ((names (make-hash-table)))
    (dolist (line (uiop:split-string (sh "llvm-nm" "--no-dyldinfo" "--defined-only" file)
                                     :separator '(#\Newline))
                  names)
      (when (> (length line) 19)
        (push (subseq line 19) (gethash (parse-integer line :end 16 :radix 16) names))))))

(test skylight-subsystems-match-the-symbols
  (with-tahoe
    (let* ((file (namestring (dyld:extract-image (cache) +skylight+ (merge-pathnames "SkyLight" (scratch)))))
           (names (nm-text file))
           (subsystems (mig:subsystems (macho:read-macho file)))
           (stubs (make-hash-table :test 'equal)))
      (is (= 9 (length subsystems)))
      (dolist (s subsystems)
        (is (find (format nil "_~a" (mig:subsystem-name s)) (gethash (mig:subsystem-address s) names)
                  :test #'string=))
        (is (some (lambda (n) (search "_server" n)) (gethash (mig:subsystem-server s) names)))
        (dolist (r (mig:subsystem-routines s))
          (is (<= (mig:subsystem-start s) (mig:routine-id r) (1- (mig:subsystem-end s))))
          (is (find (format nil "__X~a" (mig:routine-name r)) (gethash (mig:routine-stub r) names)
                    :test #'string=))
          (setf (gethash (mig:routine-name r) stubs) t)))
      (let ((missing (loop :for ns :being :the :hash-values :of names
                           :nconc (loop :for n :in ns
                                        :when (and (> (length n) 3) (string= "__X" n :end2 3)
                                                   (not (gethash (subseq n 3) stubs)))
                                          :collect n))))
        (is (null missing) "stubs in no subsystem: ~{~a~^ ~}" missing))
      (let ((rendezvous (find "_CGXCGXRendezvous_subsystem" subsystems
                              :key #'mig:subsystem-name :test #'string=)))
        (is (= 29000 (mig:subsystem-start rendezvous)))
        (is (find "CreateSession" (mig:subsystem-routines rendezvous)
                  :key #'mig:routine-name :test #'string=))))))
