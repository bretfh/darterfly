#!/bin/sh
# Compare generated Low code with the host libm, including all rounding modes.
set -eu
cd "$(dirname "$0")/.."
DARTER_FMA_TEST_DIR=$(mktemp -d /tmp/darter-fma.XXXXXX)
export DARTER_FMA_TEST_DIR
trap 'rm -rf "$DARTER_FMA_TEST_DIR"' EXIT HUP INT TERM
cat > "$DARTER_FMA_TEST_DIR/build.lisp" <<'LISP'
(require :asdf)
(asdf:load-system :darterfly/libsa)
(with-open-file
    (s (merge-pathnames "low.o" (uiop:ensure-directory-pathname
                                (uiop:getenv "DARTER_FMA_TEST_DIR")))
       :direction :output :element-type '(unsigned-byte 8))
  (write-sequence
   (darterfly/low:low-object
    '(darterfly/libsa::fma darterfly/libsa::fma-normalize
      darterfly/libsa::fma-clz darterfly/libsa::fma-single-round
      darterfly/libsa::scalbn darterfly/libsa::ldexp)) s))
LISP
guix shell -m manifest.scm -- sh -c '
  export CL_SOURCE_REGISTRY="$PWD//:$GUIX_ENVIRONMENT/share/common-lisp//"
  sbcl --no-userinit --non-interactive --load "$DARTER_FMA_TEST_DIR/build.lisp"
'
guix shell -m ports/clang/host-manifest.scm -- sh -c '
  objcopy --prefix-symbols=darter_ "$DARTER_FMA_TEST_DIR/low.o" "$DARTER_FMA_TEST_DIR/test.o"
  gcc -O2 -fno-builtin -no-pie tests/libsa-fma-host.c "$DARTER_FMA_TEST_DIR/test.o" -lm -o "$DARTER_FMA_TEST_DIR/check"
  "$DARTER_FMA_TEST_DIR/check"
'
