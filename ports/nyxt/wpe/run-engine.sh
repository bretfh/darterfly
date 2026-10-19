#!/bin/sh
set -eu
cd "$(dirname "$0")/../../.."
if [ -z "${DARTER_HTTP_FIXTURE_DIR:-}" ]; then
  export DARTER_HTTP_FIXTURE_LOG="$PWD/build/wpe-assessment/engine-fixture.log"
  sh ports/nyxt/wpe/with-http-fixture.sh sh ports/nyxt/wpe/run-engine.sh
  exec python3 ports/nyxt/wpe/check-engine-origin.py "$DARTER_HTTP_FIXTURE_LOG"
fi
mkdir -p build/wpe-assessment
guix shell -m manifest.scm -- sh -c '
  export CL_SOURCE_REGISTRY="$PWD//:$GUIX_ENVIRONMENT/share/common-lisp//"
  export ASDF_OUTPUT_TRANSLATIONS="/:$HOME/.cache/common-lisp/darterfly/"
  exec sbcl --dynamic-space-size 8192 --no-userinit --non-interactive \
    --load ports/nyxt/wpe/run-engine.lisp
'
