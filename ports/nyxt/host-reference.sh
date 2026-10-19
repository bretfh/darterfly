#!/usr/bin/env bash
# Build and test the pinned host reference in a NEW disposable directory.
set -euo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
work=$(realpath -m -- "${1:?Usage: bash host-reference.sh NEW-WORK-DIRECTORY}")
mkdir -- "$work"
export DARTERFLY_HOST_WORK=$work

guix describe -f channels > "$work/channels.scm"
guix build -L "$here/guix" cl-cef-native --cores=4 \
    > "$work/bridge-path" 2> "$work/bridge-build.log"
guix build -L "$here/guix" cl-cef-native --source > "$work/bridge-source"
runtime=$(cat "$work/bridge-path")/lib/cl-cef
source=$(cat "$work/bridge-source")

git init -q "$work/nyxt"
git -C "$work/nyxt" remote add origin https://github.com/atlas-engineer/nyxt
git -C "$work/nyxt" fetch --depth=1 origin \
    cfa068ea781fe4866ae435c2950c00c5ec51cfee
git -C "$work/nyxt" checkout --detach FETCH_HEAD
# The same commit is available at the author's new repository location.
git -C "$work/nyxt" config submodule._build/closer-mop.url \
    https://codeberg.org/pcostanza/closer-mop.git
git -C "$work/nyxt" submodule update --init --recursive --jobs=4
# Reuse the SBCL compatibility selections in the user's existing Guix recipe.
git -C "$work/nyxt/_build/named-readtables" fetch origin \
    4a96687aaebd509da100b8f1dfe6a02c745f41e7
git -C "$work/nyxt/_build/named-readtables" checkout --detach \
    4a96687aaebd509da100b8f1dfe6a02c745f41e7
git init -q "$work/nyxt/_build/mgl-pax"
git -C "$work/nyxt/_build/mgl-pax" remote add origin \
    https://github.com/melisgl/mgl-pax
git -C "$work/nyxt/_build/mgl-pax" fetch --depth=1 origin \
    e924cd01e322c1b2a5b48a442e1aa2b9bf3df964
git -C "$work/nyxt/_build/mgl-pax" checkout --detach FETCH_HEAD
git -C "$work/nyxt" submodule status --recursive > "$work/submodules.txt"

guix shell -m "$here/host-build-manifest.scm" -- sh -c '
    cd "$DARTERFLY_HOST_WORK/nyxt"
    export LD_LIBRARY_PATH="$GUIX_ENVIRONMENT/lib"
    export ASDF_OUTPUT_TRANSLATIONS="(:output-translations (t \"$DARTERFLY_HOST_WORK/fasl/\") :ignore-inherited-configuration)"
    make nyxt NYXT_RENDERER=cef NODE_SETUP=false
' > "$work/nyxt-build.log" 2>&1

guix shell -m "$here/host-test-manifest.scm" -- \
    python3 "$here/tests/cef-host-smoke.py" \
    --source "$source" --runtime "$runtime" --log-dir "$work/bridge-smoke"
guix shell -m "$here/host-test-manifest.scm" \
    openssl libfixposix sqlite enchant -- \
    python3 "$here/tests/cef-host-smoke.py" \
    --source "$source" --runtime "$runtime" --log-dir "$work/nyxt-smoke" \
    --nyxt "$work/nyxt/nyxt"
