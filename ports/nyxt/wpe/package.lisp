;;;; Materialize the browser as a normal image-build input, never a guest disk.
(require :asdf)
(asdf:load-system :darterfly/image)
(load (asdf:system-relative-pathname :darterfly "ports/nyxt/wpe/application-image.lisp"))
(in-package #:darterfly/image)
(setf *print-length* 12 *print-level* 5)
(let* ((source (or (uiop:getenv "DARTERFLY_NYXT_BUILD_ROOT")
                   (string-trim '(#\Space #\Newline #\Return)
                     (uiop:read-file-string (build-path "wpe-assessment/render-build-root.txt")))))
       (engine-config (uiop:read-file-string
                        (merge-pathnames "webkit-target/CMakeCache.txt"
                          (uiop:ensure-directory-pathname source))))
       (root (uiop:ensure-directory-pathname
               (or (uiop:getenv "DARTERFLY_NYXT_ROOT")
                   (merge-pathnames ".cache/darterfly/nyxt/root/" (user-homedir-pathname))))))
  ;; Do not advertise an incomplete update as an installable package.
  (uiop:delete-file-if-exists (merge-pathnames "usr/lib/nyxt/package.sexp" root))
  (let ((entries (nyxt-application-entries source)) (names nil))
    (dolist (entry entries)
      (destructuring-bind (kind name &optional data (mode #o644) &rest metadata) entry
        (declare (ignore metadata))
        (when (eq kind :file)
          (let ((path (merge-pathnames name root)))
            (ensure-directories-exist path)
            (with-open-file (s path :direction :output :if-exists :supersede
                                    :element-type '(unsigned-byte 8))
              (write-sequence data s))
            (sb-posix:chmod path mode)
            (push name names)))))
    (with-open-file (s (merge-pathnames "usr/lib/nyxt/package.sexp" root)
                      :direction :output :if-exists :supersede)
      (with-standard-io-syntax
        (print (list :format 1 :revision
                 (string-trim '(#\Newline) (uiop:run-program '("git" "rev-parse" "HEAD") :output :string))
                 :files (length names) :engine "WPE WebKit 2.54.1"
                 :video (not (null (search "ENABLE_VIDEO:BOOL=ON" engine-config)))
                 :audio (not (null (search "USE_GSTREAMER:BOOL=ON" engine-config)))
                 :web-audio (not (null (search "ENABLE_WEB_AUDIO:BOOL=ON" engine-config)))
                 :media-source (not (null (search "ENABLE_MEDIA_SOURCE:BOOL=ON" engine-config)))) s)))
    (format t "~&[NYXT PACKAGE READY] ~a (~d files)~%" root (length names))))
