#!/usr/bin/env python3
"""Check the independent HTTP origin for the verified Nyxt Lisp TLS probe."""
from pathlib import Path
import sys
text = Path(sys.argv[1]).read_text()
for port in (18766, 18772):
    expected = f'ORIGIN {port} "GET /nyxt HTTP/1.1" 200'
    if text.count(expected) != 2:
        raise SystemExit(f'Expected two successful requests on {port}')
    if text.count(f'TLS-SESSION {port} resumed=False') != 2:
        raise SystemExit(f'Expected full verified handshakes on {port}')
    if f'TLS-HANDSHAKE {port} ' in text:
        raise SystemExit(f'Unexpected handshake failure on {port}')
for port in range(18768, 18772):
    if f'ORIGIN {port} ' in text:
        raise SystemExit(f'Invalid-certificate origin received HTTP on {port}')
print('NYXT ORIGIN PASS: repeated verified HTTPS, no invalid-origin HTTP')
