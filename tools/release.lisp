(require :asdf)
(asdf:load-system :darterfly/test)

(defparameter *release-dir* (uiop:ensure-directory-pathname (uiop:getenv "DARTERFLY_RELEASE_DIR")))
(defparameter *release-stage* (uiop:getenv "DARTERFLY_RELEASE_STAGE"))
(setf darterfly/image::*console-log-directory*
      (merge-pathnames (format nil "logs/~a/" *release-stage*) *release-dir*))

(defun release-json (name value)
  (with-open-file (s (merge-pathnames name *release-dir*) :direction :output :if-exists :supersede)
    (write-string (com.inuoe.jzon:stringify value) s)
    (terpri s)))

(defun release-row (name value unit)
  (darterfly/qmp:dict "name" (string-downcase (string name)) "value" (if (rationalp value) (float value 1d0) value) "unit" unit))

(defun release-ask (c form)
  ;; Explicit delimiters cannot be mistaken for echoed Lisp source or old prompts.
  (darterfly/image:send c (format nil "(format t \"~%~~a~~s~~a~%\" (concatenate 'string \"RELEASE\" \"-BEGIN \") ~a (concatenate 'string \" RELEASE\" \"-END\"))" form))
  (darterfly/image:expect c (format nil "~%RELEASE-BEGIN ") :timeout 900)
  (let* ((end " RELEASE-END")
         (text (darterfly/image:expect c end :timeout 900)))
    (with-standard-io-syntax
      (let ((*read-eval* nil)) (read-from-string (subseq text 0 (- (length text) (length end))))))))

(defun release-network-sample (c)
  (multiple-value-bind (server port) (darterfly/test::host-listener)
    (let ((sender nil) (size (* 4 1024 1024)))
      (unwind-protect
           (progn
             (setf sender
                   (sb-thread:make-thread
                    (lambda ()
                      (sb-sys:with-deadline (:seconds 120)
                        (let* ((socket (sb-bsd-sockets:socket-accept server))
                               (stream (sb-bsd-sockets:socket-make-stream socket :output t :element-type '(unsigned-byte 8))))
                          (unwind-protect
                               (progn (write-sequence (make-array size :element-type '(unsigned-byte 8) :initial-element 85) stream)
                                      (finish-output stream))
                            (sb-bsd-sockets:socket-close socket)))))))
             (prog1
                 (release-ask c
                  (format nil "(progn (darterfly/net:start-network) (let ((c (darterfly/net:tcp-connect \"10.0.2.2\" ~d)) (n 0) (start (get-internal-real-time))) (unwind-protect (progn (loop while (< n ~d) for bytes = (darterfly/net:tcp-receive c :timeout 30) do (unless (and bytes (plusp (length bytes))) (error \"short network sample\")) (unless (every (lambda (b) (= b 85)) bytes) (error \"corrupt network sample\")) (incf n (length bytes))) (/ n 1048576.0 (/ (- (get-internal-real-time) start) internal-time-units-per-second))) (darterfly/net:tcp-close c))))" port size))
               (sb-thread:join-thread sender :timeout 120)))
        (sb-bsd-sockets:socket-close server)
        (when (and sender (sb-thread:thread-alive-p sender)) (sb-thread:terminate-thread sender))))))

(defun release-input-sample (c)
  ;; The reference display is 1280x800. Use the same listener/dock coordinates
  ;; as the integration test. The transcript is written by the view's DRAW.
  (flet ((click (x y)
           (darterfly/image:pointer x y)
           (darterfly/image:pointer x y t)
           (darterfly/image:pointer x y nil))
         (drawn-p (text)
           (release-ask c (format nil "(and (probe-file \"/tmp/Listener.txt\") (not (null (search ~s (uiop:read-file-string \"/tmp/Listener.txt\")))))" text))))
    (click 674 744)
    (loop repeat 100 until (drawn-p "* ") do (sleep 0.05)
          finally (unless (drawn-p "* ") (error "Listener did not open for input measurement")))
    ;; A view can finish DRAW before the compositor presents its window.
    (darterfly/test::screen-until
     (lambda (screen) (= #xffffffff (darterfly/image:pixel screen 400 500))))
    (click 400 500)
    (let ((start (get-internal-real-time)))
      (darterfly/image:send-keys "x")
      (loop repeat 100 until (drawn-p "* x") do (sleep 0.01)
            finally (unless (drawn-p "* x") (error "Keyboard event did not reach Listener")))
      (* 1000.0 (/ (- (get-internal-real-time) start) internal-time-units-per-second)))))

(defun release-measure ()
  (let ((samples nil)
        (count (parse-integer (uiop:getenv "DARTERFLY_RELEASE_SAMPLES"))))
    (dotimes (i count)
      (format t "~&Measurement ~d/~d~%" (1+ i) count)
      (let ((c (darterfly/image:bare-console :boot-args "init")))
        (unwind-protect
             (let ((boot nil) (roundtrip nil))
               (darterfly/image:expect c "init: pid 1" :timeout 120)
               (setf boot (* 1000.0 (/ (- (get-internal-real-time) (darterfly/image::console-started c)) internal-time-units-per-second)))
               (sleep 20)
               (let ((start (get-internal-real-time)))
                 (unless (= 42 (release-ask c "(+ 40 2)")) (error "console roundtrip failed"))
                 (setf roundtrip (* 1000.0 (/ (- (get-internal-real-time) start) internal-time-units-per-second))))
               (let* ((rows (release-ask c "(darterfly/bench:run :raw t)"))
                      (network (release-network-sample c))
                      (input (release-input-sample c))
                      (sample (append (mapcar (lambda (r) (release-row (first r) (second r) (third r))) rows)
                                      (list (release-row "boot-to-init-ms" boot "ms")
                                            (release-row "console-roundtrip-ms" roundtrip "ms")
                                            (release-row "gui-key-to-draw-observed-ms" input "ms")
                                            (release-row "tcp-receive-mib-s" network "MiB/s")))))
                 (push (coerce sample 'vector) samples)
                 (release-json "samples.json" (coerce (reverse samples) 'vector))))
          (darterfly/image:finish c 0))))))

(cond
  ((string= *release-stage* "bootstrap") (darterfly/image:build-sbcl))
  ((uiop:string-prefix-p "test-" *release-stage*)
   (darterfly/test:run-them (intern (string-upcase (uiop:getenv "DARTERFLY_RELEASE_TIER")) :keyword)))
  ((string= *release-stage* "image")
   ;; A distributable image must not embed the developer's nREPL key.
   (darterfly/image:usb-image :path (merge-pathnames "artifacts/darterfly-usb.img" *release-dir*) :boot-args "rd=ram init")
   (dolist (entry (list (cons "kernel" (darterfly/image:kernel-file))
                       (cons "boot.efi" (darterfly/image:boot-efi))
                       (cons "darterfly.core" (darterfly/image::darterfly-core))))
     (uiop:copy-file (cdr entry) (merge-pathnames (concatenate 'string "artifacts/" (car entry)) *release-dir*))))
  ((string= *release-stage* "image-smoke")
   (let* ((image (merge-pathnames "artifacts/darterfly-usb.img" *release-dir*))
          (args (darterfly/image::bare-qemu image))
          ;; Snapshot the actual published GPT image so the smoke test cannot alter it.
          (args (mapcar (lambda (s) (if (search "if=none,id=esp," s)
                                        (concatenate 'string s ",snapshot=on") s)) args))
          (c (darterfly/image:console :args args)))
     (unwind-protect
          (progn (darterfly/image:expect c "init: pid 1" :timeout 120)
                 (unless (= 42 (release-ask c "(+ 40 2)")) (error "release image failed smoke test"))
                 (unless (equalp (com.inuoe.jzon:parse (uiop:read-file-string (merge-pathnames "image-identity.json" *release-dir*)))
                                 (com.inuoe.jzon:parse (release-ask c "(uiop:read-file-string \"/System/Library/Release/identity.json\")")))
                   (error "release image identity does not match its evidence")))
       (darterfly/image:finish c 0))))
  ((string= *release-stage* "measure") (release-measure))
  (t (error "Unknown release stage ~s" *release-stage*)))
