#!/bin/sh
set -eu
cd "$(dirname "$0")/../../.."
mkdir -p build/wpe-assessment
guix shell -m manifest.scm -- sh -c '
  export CL_SOURCE_REGISTRY="$PWD//:$GUIX_ENVIRONMENT/share/common-lisp//"
  export ASDF_OUTPUT_TRANSLATIONS="/:$HOME/.cache/common-lisp/darterfly/"
  exec sbcl --no-userinit --non-interactive \
    --load ports/nyxt/wpe/run-render.lisp
'
