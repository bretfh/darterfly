#!/bin/sh
exec "$(dirname "$0")/target-cc.py" --cxx "$@"
