(use-modules (guix profiles) (gnu packages))
(specifications->manifest
 '("sbcl" "openssl" "libfixposix" "sqlite" "enchant"
   "pkg-config" "gcc-toolchain" "make"))
