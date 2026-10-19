#!/usr/bin/env bash
# Run with the Guix revision described by channels.scm.
set -euo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
out=${1:?Usage: bash export.sh OUTPUT-DIRECTORY}
mkdir -p -- "$out"
guix describe -f channels > "$out/channels.scm"
export_graph() {
    local name=$1
    shift
    guix graph "$@" --type=bag --backend=cyclonedx-json \
        > "$out/$name.cdx.json"
    guix graph "$@" --type=bag --backend=graphml \
        | gzip -n > "$out/$name.graphml.gz"
}
nyxt=(-L "$here/recipes" -e '(@ (dots packages nyxt) nyxt)')
export_graph nyxt-guix-build "${nyxt[@]}"
guix graph "${nyxt[@]}" --type=package --backend=cyclonedx-json \
    > "$out/nyxt-guix-declared.cdx.json"
export_graph cef-guix-build \
    -e '(@ (nongnu packages chromium) chromium-embedded-framework)'
export_graph chromium-guix-source-build ungoogled-chromium
export_graph llvm-guix-build clang llvm lld
export_graph llvm21-guix-build clang@21.1.8 llvm@21.1.8 lld@21.1.8

# Subsequent host reference, distinct from the original CEF 117 inventory.
export_graph cl-cef-host-build -L "$here/../guix" cl-cef-native
