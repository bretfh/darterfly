;; Host-only generators. Darterfly's target compiler uses the main manifest.
(use-modules (guix profiles))
(specifications->manifest
 '("gcc-toolchain@14" "cmake" "ninja" "python" "bash" "coreutils" "grep" "sed"))
