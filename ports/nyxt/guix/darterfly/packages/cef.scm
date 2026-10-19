;;; Host integration reference; libcef is an upstream binary seed here.
;;; This is not the eventual source-building Darterfly engine package.
(define-module (darterfly packages cef)
  #:use-module (guix packages)
  #:use-module (guix download)
  #:use-module (guix git-download)
  #:use-module (guix gexp)
  #:use-module ((guix licenses) #:prefix license:)
  #:use-module (guix build-system cmake)
  #:use-module (gnu packages linux)
  #:use-module (gnu packages xorg)
  #:use-module (nongnu packages chromium)
  #:export (cef-sdk-reference cl-cef-native))

(define cef-sdk-reference
  (package
    (inherit chromium-embedded-framework)
    (name "cef-sdk-reference")
    (version "147.0.14")
    (source
     (origin
       (method url-fetch)
       (uri (string-append
             "https://cef-builds.spotifycdn.com/cef_binary_"
             version "+g76d2442+chromium-147.0.7727.138_linux64_minimal.tar.bz2"))
       (sha256
        (base32 "1q3dki9klx07x2zbrjxd7m991iw44gqr58khwjx556bya80g1km2"))))
    (supported-systems '("x86_64-linux"))
    (arguments
     (list
      #:strip-binaries? #f
      #:patchelf-plan
      #~'(("Release/libcef.so"
           ("alsa-lib" "at-spi2-core" "cairo" "cups" "dbus" "expat"
            "gcc" "glib" "libc" "gtk+" "libdrm" "libx11" "libxcb"
            "libxcomposite" "libxdamage" "libxext" "libxfixes"
            "libxkbcommon" "libxrandr" "libxshmfence" "mesa" "nspr"
            ("nss" "/lib/nss") "pango" "eudev"))
          ("Release/libEGL.so" ("libc" "gcc"))
          ("Release/libGLESv2.so" ("libc" "gcc" "libx11" "libxext" "libxcb"))
          ("Release/libvk_swiftshader.so" ("libc" "gcc"))
          ("Release/libvulkan.so.1" ("libc" "gcc")))
      ;; Preserve the upstream SDK layout required by FindCEF.cmake.
      #:install-plan #~'(("." "./"))))
    (inputs (modify-inputs (package-inputs chromium-embedded-framework)
              (append eudev)))
    (synopsis "Pinned CEF SDK for the Nyxt host compatibility experiment")
    (description
     "This package preserves the CEF binary SDK layout and adjusts ELF search
paths for Guix.  It is a host integration seed, not a source build of Chromium
and not a production browser release selection.")))

(define cl-cef-native
  (package
    (name "cl-cef-native")
    (version "0.0.0-257c642")
    (source
     (origin
       (method git-fetch)
       (uri (git-reference
             (url "https://github.com/atlas-engineer/cl-cef")
             (commit "257c6421bb173cbe50d2b5a2a1066bace15347fc")))
       (file-name (git-file-name name version))
       (sha256
        (base32 "180pvmm31fw6kqlk39g76jmj2pymp8xcn1nv7hvqxhv9j9yrmcb5"))
       (patches
        (list (local-file
               (string-append
                (dirname (canonicalize-path
                          (search-path %load-path "darterfly/packages/cef.scm")))
                "/../../../patches/cl-cef-quit-on-ui-thread.patch"))))))
    (build-system cmake-build-system)
    (arguments
     (list
      #:tests? #f ; Real-engine checks run via host-reference.sh.
      #:build-type "Release"
      #:configure-flags
      #~(list (string-append "-DCEF_ROOT=" #$cef-sdk-reference))
      #:phases
      #~(modify-phases %standard-phases
          ;; Upstream has no install target. Keep the helper and resources
          ;; beside the bridge, as its default path discovery expects.
          (replace 'install
            (lambda _
              (let ((lib (string-append #$output "/lib/cl-cef")))
                (mkdir-p lib)
                (install-file "libcl-cef.so" lib)
                (install-file "cl-cef-helper" lib)
                (copy-recursively
                 (string-append #$cef-sdk-reference "/Release") lib)
                (copy-recursively
                 (string-append #$cef-sdk-reference "/Resources") lib)
                (for-each
                 (lambda (name)
                   (install-file
                    (string-append #$cef-sdk-reference "/" name)
                    (string-append #$output "/share/doc/cl-cef-native")))
                 '("LICENSE.txt" "CREDITS.html"))))))))
    (inputs (list cef-sdk-reference libx11))
    (home-page "https://github.com/atlas-engineer/cl-cef")
    (synopsis "Native bridge for Nyxt's existing CEF backend")
    (description "Build the pinned upstream cl-cef C++ bridge and helper with
CEF resources alongside them.  Lisp sources are supplied by Nyxt's source
closure; CL_CEF_LIBRARY selects this bridge without editing Nyxt.")
    (license license:bsd-3)))
