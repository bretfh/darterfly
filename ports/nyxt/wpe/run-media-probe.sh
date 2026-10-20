#!/bin/sh
set -eu
cd "$(dirname "$0")/../../.."
exec guix shell -m manifest.scm -- sh -c '
  export CL_SOURCE_REGISTRY="$PWD//:$GUIX_ENVIRONMENT/share/common-lisp//"
  export ASDF_OUTPUT_TRANSLATIONS="/:$HOME/.cache/common-lisp/darterfly/"
  exec sbcl --dynamic-space-size 8192 --no-userinit --non-interactive --load ports/nyxt/wpe/run-media-probe.lisp
'
