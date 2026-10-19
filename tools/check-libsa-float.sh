#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
DARTER_FLOAT_TEST_DIR=$(mktemp -d /tmp/darter-float.XXXXXX)
export DARTER_FLOAT_TEST_DIR
trap 'rm -rf "$DARTER_FLOAT_TEST_DIR"' EXIT HUP INT TERM
cat > "$DARTER_FLOAT_TEST_DIR/build.lisp" <<'LISP'
(require :asdf)
(asdf:load-system :darterfly/libsa)
(with-open-file
    (s (merge-pathnames "low.o" (uiop:ensure-directory-pathname
                                (uiop:getenv "DARTER_FLOAT_TEST_DIR")))
       :direction :output :element-type '(unsigned-byte 8))
  (write-sequence
   (darterfly/low::object
    (append
     (mapcar #'darterfly/low::function-routine
       (mapcar #'darterfly/low::low-function
         '("nan_p" "infinite_p" "negate" "fabs" "copysign" "floor"
           "round" "ldexp" "roundf" "lroundf" "nextafterf" "fmaf"
           "lrintf" "llroundf" "fmin" "fmax" "fminf" "fmaxf" "remainder" "trunc" "rint" "llround" "ldexpf" "frexp" "frexpf"
           "log" "logf" "exp2" "exp2f" "remainderf" "exp" "erff_pp" "erff_qq" "erff_pa" "erff_qa" "erff_ra"
           "erff_sa" "erff_rb" "erff_sb" "erff_tail" "erff")))
     (darterfly/libsa::long-double-routines))) s))
LISP
guix shell -m manifest.scm -- sh -ec '
  export CL_SOURCE_REGISTRY="$PWD//:$GUIX_ENVIRONMENT/share/common-lisp//"
  sbcl --no-userinit --non-interactive --load "$DARTER_FLOAT_TEST_DIR/build.lisp"
'
guix shell -m ports/clang/host-manifest.scm -- sh -ec '
  objcopy --prefix-symbols=darter_ "$DARTER_FLOAT_TEST_DIR/low.o" "$DARTER_FLOAT_TEST_DIR/test.o"
  gcc -O2 -fno-builtin -frounding-math -no-pie tests/libsa-float-host.c \
    "$DARTER_FLOAT_TEST_DIR/test.o" -lm -o "$DARTER_FLOAT_TEST_DIR/check"
  "$DARTER_FLOAT_TEST_DIR/check"
'
