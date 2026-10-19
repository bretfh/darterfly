#!/bin/sh
# Compare generated address, glob and DNS parsing code with the host libc.
set -eu
cd "$(dirname "$0")/.."
DARTER_NETWORK_TEST_DIR=$(mktemp -d /tmp/darter-network.XXXXXX)
export DARTER_NETWORK_TEST_DIR
trap 'rm -rf "$DARTER_NETWORK_TEST_DIR"' EXIT HUP INT TERM
cat > "$DARTER_NETWORK_TEST_DIR/build.lisp" <<'LISP'
(require :asdf)
(asdf:load-system :darterfly/libsa)
(with-open-file
    (s (merge-pathnames "low.o" (uiop:ensure-directory-pathname
                                (uiop:getenv "DARTER_NETWORK_TEST_DIR")))
       :direction :output :element-type '(unsigned-byte 8))
  (write-sequence
   (darterfly/low:low-object
    '(darterfly/libsa::inet4-parse darterfly/libsa::inet-hex
       darterfly/libsa::inet6-finish darterfly/libsa::inet6-parse
       darterfly/libsa::inet_pton darterfly/libsa::inet-word
       darterfly/libsa::inet4-format darterfly/libsa::inet6-format
       darterfly/libsa::inet_ntop darterfly/libsa::fail-with
       darterfly/libsa::glob-char darterfly/libsa::glob-class
       darterfly/libsa::glob-bracket darterfly/libsa::fnmatch
       darterfly/libsa::dn_expand)) s))
LISP
guix shell -m manifest.scm -- sh -ec '
  export CL_SOURCE_REGISTRY="$PWD//:$GUIX_ENVIRONMENT/share/common-lisp//"
  sbcl --no-userinit --non-interactive --load "$DARTER_NETWORK_TEST_DIR/build.lisp"
'
guix shell -m ports/clang/host-manifest.scm -- sh -ec '
  objcopy --prefix-symbols=darter_ "$DARTER_NETWORK_TEST_DIR/low.o" "$DARTER_NETWORK_TEST_DIR/test.o"
  objcopy --redefine-sym darter_malloc=malloc --redefine-sym darter_free=free \
    --redefine-sym darter_memset=memset --redefine-sym darter_memcpy=memcpy \
    --redefine-sym darter_memmove=memmove --redefine-sym darter_strlen=strlen \
    --redefine-sym darter___errno_location=__errno_location \
    "$DARTER_NETWORK_TEST_DIR/test.o"
  for name in calloc snprintf strncmp isalnum isalpha iscntrl isdigit isgraph islower isprint ispunct isspace isupper isxdigit; do
    objcopy --redefine-sym "darter_$name=$name" "$DARTER_NETWORK_TEST_DIR/test.o"
  done
  gcc -O2 -fno-builtin -no-pie tests/libsa-network-host.c \
    "$DARTER_NETWORK_TEST_DIR/test.o" -lresolv -o "$DARTER_NETWORK_TEST_DIR/check"
  "$DARTER_NETWORK_TEST_DIR/check"
'
