#!/usr/bin/env python3
"""Record successful native Nyxt core qualification, separately from its UI."""
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys

r = Path(__file__).resolve().parents[3]
p = r / 'ports/nyxt/wpe'
b = r / 'build/wpe-assessment'
w = Path((b / 'render-build-root.txt').read_text().strip())
log = (b / 'nyxt-build-guest.log').read_text()
markers = ['INPUTS LIBSA PASS', 'INPUTS FIXPOSIX SPAWN PASS',
           'IOLIB PROCESS PASS', 'SQLITE MEMORY PASS', 'LISP BUILD PASS',
           'CORE COMMAND PASS', 'OCICL HTTPS PASS', 'OCICL HTTPS RECOVERY PASS',
           'OCICL HTTPS HRR PASS', 'QUALIFICATION PASS',
           'CERTIFICATE REJECTED EXPIRED', 'CERTIFICATE REJECTED FUTURE',
           'CERTIFICATE REJECTED WRONG-HOST', 'CERTIFICATE REJECTED UNTRUSTED']
assert all('[NYXT ' + marker + ']' in log for marker in markers)
assert '[NYXT WORLD RESULT (:EXIT 0' in log
assert '[NYXT LISP BUILD ERROR]' not in log
host = (b / 'nyxt-tls-qualified-host.log').read_text()
assert '[OCICL HOST REPEATED HTTPS PASS]' in host
assert 'Pass: 75 (100%)' in (b / 'nyxt-native-host.log').read_text()
for name in ['nyxt-origin.log', 'nyxt-tls-host-origin.log']:
    subprocess.run([sys.executable, p / 'check-nyxt-origin.py', b / name], check=True)

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

logs = p / 'qualification-logs'
logs.mkdir(exist_ok=True)
records = {}
for source, dest in [('nyxt-build-guest.log', 'nyxt-source-build.log'),
                     ('nyxt-origin.log', 'nyxt-origin.log'),
                     ('nyxt-tls-qualified-host.log', 'nyxt-tls-host.log'),
                     ('nyxt-tls-host-origin.log', 'nyxt-tls-host-origin.log'),
                     ('nyxt-native-host.log', 'nyxt-native-host.log')]:
    target = logs / dest
    shutil.copyfile(b / source, target)
    records[source] = {'path': str(target.relative_to(p)), 'sha256': digest(target)}
files = {r / 'manifest.scm', r / 'src/apps/ocicl.lisp',
         b / 'nyxt-source-manifest.json', r / 'tests/native.lisp'}
for directory in ['src/libsa', 'src/bsd', 'src/low', 'src/run', 'src/worlds',
                  'ports/ocicl']:
    files.update(x for x in (r / directory).rglob('*') if x.is_file())
for pattern in ['*nyxt*.py', '*nyxt*.sh', '*nyxt*.lisp', '*nyxt*.c',
                'fixposix*.c', 'fixposix*.inc', 'test-ocicl*.lisp',
                'http-fixture.py', 'with-http-fixture.sh', 'target-cc.py']:
    files.update(p.glob(pattern))
artifacts = [w / 'nyxt-native/root/usr/bin/pkg-config',
             w / 'nyxt-native/root/usr/lib/libfixposix.so',
             w / 'nyxt-native/root/usr/lib/libsqlite3.so']
source = json.loads((b / 'nyxt-source-manifest.json').read_text())
data = {
    'recorded_utc': datetime.now(timezone.utc).isoformat(),
    'branch': subprocess.check_output(['git', 'branch', '--show-current'], cwd=r, text=True).strip(),
    'head': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=r, text=True).strip(),
    'state': 'Uncommitted worktree; existing staged D2 merge preserved.',
    'complete_nyxt_build': True,
    'clean_disk': '--clean-disk' in sys.argv,
    'nyxt_revision': source['revision'],
    'qualified': 'Native Nyxt Lisp build and live command, IOLib child process, SQLite memory queries/rollback, native CFFI compiler helpers, OCICL verified HTTPS and certificate rejection in an isolated Darterfly world under normal init; exit zero.',
    'current_failure': None,
    'browser_window_running': False,
    'not_qualified': ['Nyxt WPE renderer and native window/input integration',
                      'Persistent browser databases and record locking',
                      'Complete browser application lifecycle'],
    'limitations': ['Optional Enchant spelling library unavailable.',
                   'Shared OCICL pure-tls is TLS 1.3 only; verified requests use full certificate handshakes, with cached PSKs disabled by the packaged guard.',
                   'WebKit HTTPS is independently qualified; this record does not prove Nyxt renderer integration.'],
    'native_inputs': {
        'pkgconf': {'version': '2.5.1', 'guix_source': str((b / 'pkgconf-source').resolve())},
        'libfixposix': {'version': '0.4.3', 'guix_source': str((b / 'fixposix-source').resolve())},
        'sqlite': {'version': '3.53.1', 'source': 'Same Guix source as the WPE build.'}},
    'shared_systems': [line for line in log.splitlines() if line.startswith('[NYXT SHARED SYSTEM]')],
    'checks': markers,
    'logs': records,
    'inputs_sha256': {str(x.relative_to(r)): digest(x) for x in sorted(files)},
    'artifacts_sha256': {str(x): digest(x) for x in artifacts},
}
(p / 'nyxt-build-evidence.json').write_text(json.dumps(data, indent=2) + '\n')
print('Recorded native Nyxt core qualification:', p / 'nyxt-build-evidence.json')
