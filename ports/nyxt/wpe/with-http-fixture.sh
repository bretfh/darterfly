#!/bin/sh
set -eu
cd "$(dirname "$0")/../../.."
DARTER_HTTP_FIXTURE_DIR=$(mktemp -d /tmp/darter-http.XXXXXX)
export DARTER_HTTP_FIXTURE_DIR
fixture_pid=
cleanup() {
  if [ -n "$fixture_pid" ]; then
    kill "$fixture_pid" 2>/dev/null || true
    wait "$fixture_pid" 2>/dev/null || true
  fi
  if [ -n "${DARTER_HTTP_FIXTURE_LOG:-}" ]; then
    cp "$DARTER_HTTP_FIXTURE_DIR/server.log" "$DARTER_HTTP_FIXTURE_LOG"
  fi
  rm -rf "$DARTER_HTTP_FIXTURE_DIR"
}
trap cleanup EXIT HUP INT TERM
python3 ports/nyxt/wpe/http-fixture.py --directory "$DARTER_HTTP_FIXTURE_DIR" --tls \
  > "$DARTER_HTTP_FIXTURE_DIR/server.log" 2>&1 &
fixture_pid=$!
for attempt in $(seq 1 100); do
  [ ! -f "$DARTER_HTTP_FIXTURE_DIR/ready" ] || break
  if ! kill -0 "$fixture_pid" 2>/dev/null; then
    cat "$DARTER_HTTP_FIXTURE_DIR/server.log"
    exit 1
  fi
  sleep 0.1
done
[ -f "$DARTER_HTTP_FIXTURE_DIR/ready" ]
"$@"
