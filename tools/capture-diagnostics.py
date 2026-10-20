#!/usr/bin/env python3
"""Keep bounded authenticated diagnostic samples on a separate host, including gaps."""
import argparse
import datetime
import json
import os
from pathlib import Path
import socket
import time

MAX_REPLY = 1024 * 1024


def encode(value):
    if isinstance(value, str):
        value = value.encode()
        return str(len(value)).encode() + b":" + value
    if isinstance(value, dict):
        return b"d" + b"".join(encode(k) + encode(v) for k, v in value.items()) + b"e"
    raise TypeError(type(value))


class Reader:
    def __init__(self, stream):
        self.stream = stream
        self.left = MAX_REPLY

    def take(self, n=1):
        if not 0 <= n <= self.left:
            raise ValueError("diagnostic reply exceeds limit")
        result = self.stream.read(n)
        if len(result) != n:
            raise EOFError("incomplete diagnostic reply")
        self.left -= n
        return result

    def read(self, tag=None, depth=0):
        if depth > 20:
            raise ValueError("reply nesting exceeds limit")
        tag = self.take() if tag is None else tag
        if tag in (b"d", b"l"):
            values = []
            while (item := self.take()) != b"e":
                values.append(self.read(item, depth + 1))
            if tag == b"d":
                if len(values) % 2:
                    raise ValueError("odd dictionary")
                return dict(zip(values[::2], values[1::2]))
            return values
        if tag == b"i":
            value = b""
            while (char := self.take()) != b"e":
                value += char
                if len(value) > 24:
                    raise ValueError("integer exceeds limit")
            return int(value)
        length = tag
        while (char := self.take()) != b":":
            length += char
            if len(length) > 8:
                raise ValueError("length exceeds limit")
        return self.take(int(length)).decode("utf-8")


def sample(host, port, key, timeout):
    with socket.create_connection((host, port), timeout=timeout) as sock:
        sock.settimeout(timeout)
        sock.sendall(encode({"op": "diagnostics", "id": "capture", "key": key}))
        with sock.makefile("rb") as stream:
            reply = Reader(stream).read()
        if not isinstance(reply, dict):
            raise ValueError("diagnostic reply is not a dictionary")
        if reply.get("status") != ["done"]:
            raise RuntimeError("diagnostics status: " + repr(reply.get("status")))
        return reply


def capture(host, port, key, output, count, interval, timeout):
    # Exclusive creation protects earlier evidence. fsync each record so a target
    # reboot cannot erase samples already acknowledged by this recording host.
    with open(output, "x", encoding="utf-8") as stream:
        os.chmod(output, 0o600)
        for index in range(count):
            started = time.monotonic()
            record = {"sample": index, "utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
                      "host": host, "port": port}
            try:
                record["reply"] = sample(host, port, key, timeout)
            except (OSError, EOFError, ValueError, RuntimeError) as error:
                record["error"] = str(error)
            record["elapsed_ms"] = (time.monotonic() - started) * 1000
            # Scrub before JSON escaping: keys may contain quote characters.
            def redact(value):
                if isinstance(value, str):
                    return value.replace(key, "[redacted]")
                if isinstance(value, dict):
                    return {k: redact(v) for k, v in value.items()}
                if isinstance(value, list):
                    return [redact(v) for v in value]
                return value
            stream.write(json.dumps(redact(record)) + "\n")
            stream.flush()
            os.fsync(stream.fileno())
            if index + 1 < count:
                time.sleep(max(0, interval - (time.monotonic() - started)))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", required=True)
    parser.add_argument("--port", type=int, default=4011)
    parser.add_argument("--key-file", type=Path, default=Path(__file__).resolve().parents[1] / "build/nrepl.key")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--count", type=int, default=300)
    parser.add_argument("--interval", type=float, default=1)
    parser.add_argument("--timeout", type=float, default=2)
    args = parser.parse_args()
    if not 1 <= args.count <= 86400 or args.interval < .1 or not 0 < args.timeout <= 60:
        parser.error("count must be 1..86400, interval >= .1, timeout in (0,60]")
    key = args.key_file.read_text().strip()
    if not key:
        parser.error("empty key file")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    capture(args.host, args.port, key, args.output, args.count, args.interval, args.timeout)


if __name__ == "__main__":
    main()
