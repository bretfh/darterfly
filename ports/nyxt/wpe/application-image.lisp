;;;; Optional installed Nyxt application, reusing the pinned build products.
;;;; No fixture CA, test hook or qualification launcher is installed here.
(in-package #:darterfly/image)
(defun nyxt-application-entries (root)
  (let ((root (uiop:ensure-directory-pathname root)))
    (dolist (name '("nyxt-engine" "WPEWebProcess" "WPENetworkProcess"))
      (darterfly/cc:link-native-program
        (merge-pathnames (concatenate 'string "engine/" name) root)
        (list (namestring (merge-pathnames
                (concatenate 'string "engine/" name "-guest.o") root))
              (namestring (build-path "cxx/runtime.o"))
              (namestring (build-path "cxx/crt0.o")))
        :map-file (build-path (format nil "wpe-assessment/~a-app.map" name))))
    (multiple-value-bind (compiler support)
        (darterfly/cc:build-native-tcc (build-path "nyxt-app-toolchain/tcc")
          :compiler (tcc) :tcc-dir (namestring (tcc-stage 2))
          :directory (source "") :work (build-path "nyxt-app-toolchain/"))
    (append
      (list (list :file "usr/bin/tcc" (octets compiler) #o755))
      (loop for object in support collect
        (list :file (format nil "usr/lib/nyxt/tcc-support/~a" (file-namestring object))
                    (octets object)))
      (list (list :file "System/Applications/Nyxt.app/Contents/Programs/Nyxt"
                  (text (format nil "#!darterfly Nyxt~%")) #o755)
            (list :file "usr/lib/nyxt/tls-source-id"
                  (sb-ext:string-to-octets
                    (namestring (truename (merge-pathnames "share/ocicl-source/"
                      (uiop:ensure-directory-pathname (uiop:getenv "GUIX_ENVIRONMENT")))))
                    :external-format :utf-8)))
      (loop for (source target) in
        '(("engine/nyxt-engine" "usr/bin/nyxt-wpe-engine")
          ("engine/WPEWebProcess" "usr/libexec/wpe-webkit-2.0/WPEWebProcess")
          ("engine/WPENetworkProcess" "usr/libexec/wpe-webkit-2.0/WPENetworkProcess"))
        collect (list :file target (octets (merge-pathnames source root)) #o755))
      (tree-entries (merge-pathnames "nyxt-native/root/usr/" root) "usr")
      (tree-entries (merge-pathnames "nyxt-source/" root) "usr/src/nyxt")
      (loop for name in '("nyxt-application" "nyxt-load" "nyxt-toolchain"
                         "nyxt-wire" "nyxt-windows" "nyxt-renderer")
        collect (list :file (format nil "usr/lib/nyxt/~a.lisp" name)
                      (octets (source (format nil "ports/nyxt/wpe/~a.lisp" name)))))
      (list (list :file "usr/lib/nyxt/crt0.o" (octets (build-path "cxx/crt0.o")))
            (list :file "usr/bin/ld.lld" (octets (build-path "lld/ld.lld")) #o755)
            (list :file "usr/lib/nyxt/native.ld" (octets (source "ports/lld/native.ld")))
            (list :file "etc/fonts/fonts.conf"
              (text (format nil "<?xml version=~s?>~%<fontconfig><dir>/System/Library/Fonts</dir><cachedir>/Users/darterfly/.cache/fontconfig</cachedir></fontconfig>~%" "1.0"))))))))

(defun with-entry-directories (entries)
  (let ((dirs nil))
    (dolist (entry entries)
      (dolist (dir (parents (concatenate 'string "/" (second entry))))
        (pushnew (string-left-trim "/" dir) dirs :test #'equal)))
    (append (loop for dir in (sort dirs #'< :key #'length)
                  unless (equal dir "") collect (list :dir dir)) entries)))
