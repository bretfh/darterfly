#!/usr/bin/env python3
"""Record the native browser run only after every integration gate passes."""
import os
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import shutil
import struct
import subprocess
import zlib

repo = Path(__file__).resolve().parents[3]
port = repo / 'ports/nyxt/wpe'
build = repo / 'build/wpe-assessment'
root = Path((build / 'render-build-root.txt').read_text().strip())
log = (build / 'nyxt-build-guest.log').read_text()
markers = [
    '[NYXT INPUTS LIBSA PASS]', '[NYXT INPUTS FIXPOSIX SPAWN PASS]',
    '[NYXT SPAWN ENVIRONMENT PASS]', '[NYXT IOLIB PROCESS PASS]',
    '[NYXT SQLITE MEMORY PASS]', '[NYXT LISP BUILD PASS]',
    '[NYXT CORE COMMAND PASS]', '[NYXT OCICL HTTPS PASS]',
    '[NYXT OCICL HTTPS RECOVERY PASS]', '[NYXT OCICL HTTPS HRR PASS]',
    '[NYXT BROWSER NORMAL STARTUP PASS]', '[NYXT BROWSER HTTPS PAGE PASS]',
    '[NYXT BROWSER NATIVE FRAME PASS]', '[NYXT BROWSER JAVASCRIPT PASS]',
    '[NYXT BROWSER TRUSTED LISP CALLBACK PASS]',
    '[NYXT BROWSER WEB CALLBACK DENIED PASS]',
    '[NYXT BROWSER POINTER AND KEYBOARD PASS]',
    '[NYXT BROWSER TRUSTED INPUT PASS]', '[NYXT BROWSER URL PROMPT PASS]',
    '[NYXT BROWSER PROMPT TEXT PASS]', '[NYXT BROWSER COMMAND NAVIGATION PASS]',
    '[NYXT ENGINE WAIT 0]', '[NYXT BROWSER QUALIFICATION PASS]',
    '[NYXT WORLD RESULT (:EXIT 0 :FILES 0)]',
    '[NYXT BROWSER CHILDREN REAPED T]',
]
missing = [m for m in markers if m not in log]
if missing or '[NYXT DEVELOPMENT TOOLCHAIN REUSE]' in log:
    raise SystemExit(f'Full browser qualification required; missing: {missing}')
origin = (build / 'nyxt-browser-origin.log').read_text()
for path in ['/browser', '/browser?navigation=2']:
    if f'ORIGIN 18766 "GET {path} HTTP/1.1" 200' not in origin:
        raise SystemExit(f'Origin did not serve {path}')
host = (build / 'nyxt-browser-host-tests.log').read_text()
if len(re.findall(r'Fail: 0 ', host)) != 2:
    raise SystemExit('Both host regression suites must pass')

def digest(path):
    return hashlib.file_digest(path.open('rb'), 'sha256').hexdigest()

def png_from_ppm(source, target):
    with source.open('rb') as stream:
        assert stream.readline().strip() == b'P6'
        width, height = map(int, stream.readline().split())
        assert stream.readline().strip() == b'255'
        pixels = stream.read()
    assert len(pixels) == width * height * 3
    def chunk(kind, data):
        return (struct.pack('>I', len(data)) + kind + data +
                struct.pack('>I', zlib.crc32(kind + data)))
    rows = b''.join(b'\0' + pixels[y*width*3:(y+1)*width*3]
                    for y in range(height))
    target.write_bytes(b'\x89PNG\r\n\x1a\n' +
        chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0)) +
        chunk(b'IDAT', zlib.compress(rows)) + chunk(b'IEND', b''))

evidence_dir = Path(os.environ.get('DARTERFLY_WPE_EVIDENCE_DIR', Path.home() / 'org/darterfly/ports/nyxt/wpe'))
evidence_dir.mkdir(parents=True, exist_ok=True)
logs = evidence_dir / 'qualification-logs'
logs.mkdir(exist_ok=True)
records = {}
for source, name in [('nyxt-build-guest.log', 'nyxt-browser-guest.log'),
                     ('nyxt-browser-origin.log', 'nyxt-browser-origin.log'),
                     ('nyxt-browser-host-tests.log', 'nyxt-browser-host-tests.log')]:
    target = logs / name
    shutil.copyfile(build / source, target)
    records[name] = digest(target)
for name in ['nyxt-browser', 'nyxt-browser-input', 'nyxt-browser-prompt']:
    target = logs / (name + '.png')
    png_from_ppm(build / (name + '.ppm'), target)
    records[target.name] = digest(target)
files = list(port.glob('nyxt-*.lisp')) + list(port.glob('nyxt-*.cpp'))
files += [port / n for n in ['run-nyxt-build.lisp', 'build-engine-probe.py',
                             'nyxt-inputs-probe.c', 'http-fixture.py']]
files += [repo / p for p in ['src/libsa/vfs.lisp', 'src/libsa/unistd.lisp',
    'src/server/event.lisp', 'src/server/windowserver.lisp', 'src/image/efi.lisp']]
source = json.loads((build / 'nyxt-source-manifest.json').read_text())
evidence = {
    'recorded_utc': datetime.now(timezone.utc).isoformat(),
    'branch': subprocess.check_output(['git', 'branch', '--show-current'],
                                      cwd=repo, text=True).strip(),
    'head': subprocess.check_output(['git', 'rev-parse', 'HEAD'],
                                    cwd=repo, text=True).strip(),
    'worktree': subprocess.check_output(['git', 'status', '--porcelain=v1'], cwd=repo, text=True),
    'nyxt_revision': source['revision'],
    'webkit_version': '2.54.1',
    'native_browser_window_qualified': True,
    'run': 'Actual QEMU Darterfly, normal init, 8 GiB RAM, 2 GiB supervisor heap.',
    'build': 'Resumed guest source-build disk; native TCC/CFFI checks rerun. Not a fresh-disk rebuild.',
    'runtime': 'Isolated SBCL/Nyxt and WPE native worlds using shared libsa; existing WindowServer.',
    'input': 'QEMU HID click and typing; trusted DOM events; Ctrl-L prompt and Enter navigation.',
    'host_checks': sum(map(int, re.findall(r'Did (\d+) checks', host))),
    'markers': markers,
    'logs_and_screenshots_sha256': records,
    'source_sha256': {str(p.relative_to(repo)): digest(p) for p in sorted(set(files))},
    'engine_sha256': {name: digest(root / 'engine' / name)
                     for name in ['nyxt-engine', 'WPEWebProcess', 'WPENetworkProcess']},
    'remaining': ['Persistent WebKit sessions and browser-database locking',
                  'Crash recovery and broader normal-app qualification',
                  'Downloads, clipboard, wheel/motion and complete renderer API coverage',
                  'Broader real-site compatibility, media and performance qualification'],
}
(evidence_dir / 'browser-evidence.json').write_text(json.dumps(evidence, indent=2) + '\n')
print('Recorded native Nyxt browser qualification:', port / 'browser-evidence.json')
