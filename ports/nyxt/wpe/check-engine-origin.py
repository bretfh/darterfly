#!/usr/bin/env python3
"""Verify actual HTTP requests, including absence on rejected TLS origins."""
from pathlib import Path
import re
import sys
log = Path(sys.argv[1]).read_text()
requests = re.findall(r'ORIGIN (\d+) "GET ([^ ]+) HTTP/[^ ]+" (\d+)', log)
for port in (18765, 18766, 18767):
    for path in ('/page', '/page.css', '/page.js'):
        if (str(port), path, '200') not in requests:
            raise SystemExit(f'Missing successful origin request: {port} {path}')
for port in (18768, 18769, 18770, 18771):
    if any(int(actual) == port for actual, _, _ in requests):
        raise SystemExit(f'HTTP escaped certificate rejection at origin {port}')
print('ENGINE ORIGIN PASS: HTTP, TLS 1.3 and TLS 1.2 resources served; '
      'no HTTP request reached the four invalid-certificate origins')
