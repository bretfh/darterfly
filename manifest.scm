(use-modules (guix packages)
             (guix download)
             (guix git-download)
             (guix gexp)
             (guix build-system copy)
             ((guix licenses) #:prefix license:)
             (gnu packages compression)
             (gnu packages lisp))

(define tinycc-source
  (package
    (name "tinycc-source")
    (version "0.9.28-43c7708")
    (source (origin
              (method git-fetch)
              (uri (git-reference
                    (url "https://repo.or.cz/tinycc.git")
                    (commit "43c7708b85681a2fd4451c8a541af4494a8919b2")))
              (file-name (git-file-name "tinycc" version))
              (sha256 (base32 "1i0lgnamjyp8183dx2ijv1qr8h62cy727gvcw8r8ja4086ymfs6r"))))
    (build-system copy-build-system)
    (arguments (list #:install-plan ''(("." "share/tinycc-source/"))))
    (home-page "https://repo.or.cz/tinycc.git")
    (synopsis "TinyCC's source, which finch builds its C compiler from")
    (description "TinyCC at a pinned mob revision.")
    (license license:lgpl2.1+)))

(define sbcl-source
  (package
    (name "sbcl-source")
    (version (package-version sbcl))
    (source (package-source sbcl))
    (build-system copy-build-system)
    (arguments (list #:install-plan ''(("." "share/sbcl-source/"))))
    (native-inputs (list zstd))
    (home-page "https://www.sbcl.org/")
    (synopsis "SBCL's source, which finch builds its Lisp from")
    (description "SBCL's source as guix prepares it.")
    (license license:public-domain)))

(packages->manifest
 (append
  (map specification->package
       (list "sbcl"
             "sbcl-fiveam"
             "sbcl-alexandria"
             "sbcl-net.didierverna.asdf-flv"
             "sbcl-trivial-backtrace"
             "sbcl-plump"
             "sbcl-array-utils"
             "sbcl-documentation-utils"
             "sbcl-trivial-indent"
             "sbcl-jzon"
             "sbcl-closer-mop"
             "sbcl-flexi-streams"
             "sbcl-float-features"
             "sbcl-trivial-gray-streams"
             "sbcl-trivial-features"
             "coreutils"
             "clang"
             "gcc-toolchain"
             "make"
             "lld"
             "llvm"
             "python"
             "qemu"
             "dosfstools"
             "mtools"
             "ovmf-x86-64"
             "acpica"
             "openssh"
             "sshpass"
             "curl"
             "tar"
             "gzip"
             "sbcl-zpb-ttf"
             "sbcl-cl-vectors"
             "sbcl-chipz"
             "nss-certs"
             "tzdata"
             "font-adwaita"
             "adwaita-icon-theme"
             "librsvg"))
  (list sbcl-source tinycc-source)))
