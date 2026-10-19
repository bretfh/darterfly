#!/bin/sh
# Run from the repository root, inside host-build-manifest.scm's Guix shell.
set -eu
: "${CEF_PROBE_SDK:?Set CEF_PROBE_SDK to the pinned CEF SDK}"
: "${CEF_PROBE_RUNTIME:?Set CEF_PROBE_RUNTIME to the pinned runtime directory}"
mkdir -p build/cef-engine
"${CC:-gcc}" -std=c11 -D_DEFAULT_SOURCE -O1 -g \
    -I"$CEF_PROBE_SDK" ports/nyxt/engine/osr-probe.c \
    -L"$CEF_PROBE_RUNTIME" -Wl,-rpath,"$CEF_PROBE_RUNTIME" -lcef \
    -o build/cef-engine/osr-probe
