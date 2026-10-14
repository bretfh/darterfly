(use-modules (guix packages)
             (guix download)
             (guix gexp)
             (guix build-system copy)
             ((guix licenses) #:prefix license:)
             (gnu packages compression))

(define (acidanthera repo name version hash plan)
  (package
    (name (string-downcase name))
    (version version)
    (source (origin
              (method url-fetch)
              (uri (string-append "https://github.com/acidanthera/" repo
                                  "/releases/download/" version "/"
                                  name "-" version "-RELEASE.zip"))
              (sha256 (base32 hash))))
    (build-system copy-build-system)
    (arguments
     (list #:install-plan plan
           #:phases
           #~(modify-phases %standard-phases
               (replace 'unpack
                 (lambda* (#:key source #:allow-other-keys)
                   (invoke "unzip" "-q" source))))))
    (native-inputs (list unzip))
    (home-page (string-append "https://github.com/acidanthera/" repo))
    (synopsis name)
    (description name)
    (license license:bsd-3)))

(define opencore
  (acidanthera "OpenCorePkg" "OpenCore" "1.0.8"
               "0yyjwq5iki4v1c2r4vl40vafsisrjvgi19vyv52jdjvf46vyh490"
               ''(("X64/EFI" "share/opencore/EFI")
                  ("Docs/Sample.plist" "share/opencore/Sample.plist")
                  ("Utilities/ocvalidate/ocvalidate.linux" "bin/ocvalidate"))))

(define lilu
  (acidanthera "Lilu" "Lilu" "1.7.2"
               "1f1spzd646viqimab9jlcqyz28lmm1lykwixlcii1c5arxypv5jk"
               ''(("Lilu.kext" "share/opencore/Kexts/Lilu.kext"))))

(define virtualsmc
  (acidanthera "VirtualSMC" "VirtualSMC" "1.3.8"
               "12yyahx83xzg690wsahj65jzfp0gwwbys4srvyyb0khvz6maha9f"
               ''(("Kexts/VirtualSMC.kext" "share/opencore/Kexts/VirtualSMC.kext"))))

(define whatevergreen
  (acidanthera "WhateverGreen" "WhateverGreen" "1.7.1"
               "15aw5vajw2k6b6yr8czhg48h9mq1phf15nq6fqiwxv4h0bad5z8v"
               ''(("WhateverGreen.kext" "share/opencore/Kexts/WhateverGreen.kext"))))

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
             "ovmf-x86-64"
             "acpica"
             "openssh"
             "sshpass"
             "curl"
             "tar"
             "gzip"
             "linux-libre"
             "sbcl-zpb-ttf"
             "sbcl-cl-vectors"
             "sbcl-chipz"
             "font-adwaita"))
  (list opencore lilu virtualsmc whatevergreen)))
