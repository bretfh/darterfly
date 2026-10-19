#!/usr/bin/env python3
"""Record normal-app qualification separately from the source-build baseline."""
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
guest = (build / 'nyxt-app-guest.log').read_text()
host = (build / 'nyxt-app-host.log').read_text()
markers = [
    '[NYXT APP TEST TRUST STORE PASS]', '[NYXT APPLICATION READY]', '[NYXT NORMAL APP WORLD PASS]',
    '[NYXT APP SINGLE INSTANCE PASS]', '[NYXT BROWSER HTTPS PAGE PASS]',
    '[NYXT BROWSER NATIVE FRAME PASS]', '[NYXT BROWSER JAVASCRIPT PASS]',
    '[NYXT BROWSER TRUSTED LISP CALLBACK PASS]',
    '[NYXT BROWSER WEB CALLBACK DENIED PASS]',
    '[NYXT BROWSER POINTER AND KEYBOARD PASS]',
    '[NYXT BROWSER TRUSTED INPUT PASS]', '[NYXT BROWSER URL PROMPT PASS]',
    '[NYXT BROWSER PROMPT TEXT PASS]', '[NYXT BROWSER COMMAND NAVIGATION PASS]',
    '[NYXT BROWSER LATE PROMPT UPDATE PASS]',
    '[NYXT BROWSER QUALIFICATION PASS]', '[NYXT APP CLEANUP PASS]',
    '[NYXT APP RELAUNCH PASS]', '[NYXT APP QUIT PASS]',
]
missing = [marker for marker in markers if marker not in guest]
if missing or '[NYXT APP QUALIFICATION PASS]' not in host:
    raise SystemExit(f'Complete normal-app qualification required: {missing}')
if any(marker in guest for marker in ['[NYXT APP CHECK FAILED]',
                                      '[NYXT APPLICATION FAILED]',
                                      'debugger invoked', 'Unhandled ', 'unhandled condition']):
    raise SystemExit('Guest contains a failure')
origin = (build / 'nyxt-app-origin.log').read_text()
for url in ['/browser', '/browser?navigation=2']:
    if f'ORIGIN 18766 "GET {url} HTTP/1.1" 200' not in origin:
        raise SystemExit(f'HTTPS origin did not serve {url}')
checks = (build / 'nyxt-app-host-tests.log').read_text()
os_checks = (build / 'nyxt-app-os-tests.log').read_text()
for name, log, suites in [('host', checks, 3), ('OS', os_checks, 2)]:
    if len(re.findall(r'Fail: 0 ', log)) != suites:
        raise SystemExit(f'{name} regression suites did not all pass')

legacy = (build / 'integrated-browser-host.log').read_text()
for marker in ['[NYXT BROWSER QUALIFICATION PASS]',
               '[NYXT WORLD RESULT (:EXIT 0',
               '[NYXT BROWSER CHILDREN REAPED T]']:
    if marker not in legacy:
        raise SystemExit(f'Legacy browser regression missing: {marker}')

def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()

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

logs = port / 'qualification-logs'
records = {}
for name in ['nyxt-app-host.log', 'nyxt-app-guest.log', 'nyxt-app-origin.log',
             'nyxt-app-host-tests.log', 'nyxt-app-os-tests.log',
             'integrated-browser-host.log', 'integrated-browser-origin.log']:
    target = logs / name
    shutil.copyfile(build / name, target)
    records[name] = digest(target)
for name in ['blank', 'input', 'prompt', 'page']:
    target = logs / f'nyxt-app-{name}.png'
    png_from_ppm(build / f'nyxt-app-{name}.ppm', target)
    records[target.name] = digest(target)
source_files = list(port.glob('nyxt-*.lisp')) + [
    port / 'application-image.lisp', port / 'run-nyxt-app.lisp',
    port / 'run-nyxt-app.sh', port / 'nyxt-engine.cpp']
source_files += [repo / name for name in [
    'darterfly.asd', 'src/apps/open.lisp', 'src/apps/session.lisp',
    'src/apps/nyxt.lisp', 'src/cc/native.lisp',
    'src/libsa/stdio.lisp', 'tests/native-bsd-probe.c']]

def git(*args):
    return subprocess.check_output(['git', *args], cwd=repo, text=True).strip()

manifest = json.loads((build / 'nyxt-source-manifest.json').read_text())
for name, expected in manifest['files_sha256'].items():
    if digest(root / 'nyxt-source' / name) != expected:
        raise SystemExit(f'Pinned Nyxt source changed: {name}')

evidence = {
    'recorded_utc': datetime.now(timezone.utc).isoformat(),
    'branch': git('branch', '--show-current'), 'head': git('rev-parse', 'HEAD'),
    'integrated_master': '54ef1890a5892006bcf107ac6225e01dee8be090',
    'nyxt_revision': manifest['revision'],
    'webkit_version': '2.54.1',
    'unchanged_nyxt_source_files_verified': len(manifest['files_sha256']),
    'run': 'Actual QEMU Darterfly; normal init, Dock HID launch, 8 GiB RAM, 2 GiB supervisor and Nyxt heaps.',
    'install': 'Optional application entries installed onto resumed source-build disk; cached dependency FASLs.',
    'runtime': 'Init-managed Nyxt app world; direct Layer world client; native WPE processes with shared libsa.',
    'upstream': 'No new changes to the pinned Nyxt application sources in this integration.',
    'test_only': 'Fixture CA added only to test disk; attached-world assertions after ordinary Dock launch.',
    'host_checks': sum(map(int, re.findall(r'Did (\d+) checks', checks))),
    'os_regression_checks': sum(map(int, re.findall(r'Did (\d+) checks', os_checks))),
    'markers': markers,
    'logs_and_screenshots_sha256': records,
    'source_sha256': {str(p.relative_to(repo)): digest(p) for p in sorted(set(source_files))},
    'engine_sha256': {name: digest(root / 'engine' / name)
                     for name in ['nyxt-engine', 'WPEWebProcess', 'WPENetworkProcess']},
    'legacy_browser_regression': 'Cached/resumed browser harness passes with direct Layer presentation; not a clean source rebuild.',
    'remaining': ['Bounded crash recovery and repeated lifecycle stress',
                  'Persistent WebKit sessions and database locking',
                  'Complete input/renderer APIs and broader site compatibility',
                  'Fresh build/install and reboot qualification'],
}
(port / 'app-evidence.json').write_text(json.dumps(evidence, indent=2) + '\n')
print('Recorded normal Nyxt application qualification:', port / 'app-evidence.json')
