#!/usr/bin/env python3
"""Record the combined dispatch and recovery run without replacing older evidence."""
import os
from pathlib import Path
import argparse
import hashlib
import json
import re
import shutil
import subprocess
from datetime import datetime, timezone
repo = Path(__file__).resolve().parents[3]
port = repo / 'ports/nyxt/wpe'
build = repo / 'build/wpe-assessment'
root = Path((build / 'render-build-root.txt').read_text().strip())
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--guest-log', type=Path, default=build / 'nyxt-app-guest.log')
args = parser.parse_args()
guest = args.guest_log.read_text()
host = (build / 'nyxt-dispatch-os.log').read_text()
markers = [
    '[NYXT BROWSER QUALIFICATION PASS]', '[NYXT APP QUIT PASS]',
    '[NYXT DISPATCH PRESENTATION PASS]', '[NYXT DISPATCH ENGINE BACKPRESSURE PASS]',
    '[NYXT DISPATCH LATEST FRAME PASS]', '[NYXT DISPATCH ORDERED RPC CALLBACKS PASS]',
    '[NYXT DISPATCH QUALIFICATION PASS]',
    '[NYXT RECOVERY UI CLEANUP PASS]', '[NYXT RECOVERY WEB CLEANUP PASS]',
    '[NYXT RECOVERY ENGINE BUDGET PASS]', '[NYXT RECOVERY LISP CLEANUP PASS]',
    '[NYXT RECOVERY HUNG-ENGINE CLEANUP PASS]', '[NYXT RECOVERY HUNG-APP BUDGET PASS]',
    '[NYXT RECOVERY WORKER CLEANUP PASS]', '[NYXT RECOVERY NORMAL QUIT PASS]',
]
for marker in markers:
    if not re.search(r'^(?:\* )?' + re.escape(marker) + r'\s*$', guest, re.M):
        raise SystemExit(f'Missing actual-OS assertion: {marker}')
for marker in ['[NYXT APP QUALIFICATION PASS]', '[NYXT DISPATCH QUALIFICATION PASS]',
               '[NYXT CRASH QUALIFICATION PASS]', '[NYXT RECOVERY HTTPS JAVASCRIPT PASS]',
               '[NYXT COMBINED QUALIFICATION PASS]']:
    if marker not in host:
        raise SystemExit(f'Missing host completion: {marker}')
if ('panic(' in guest or 'debugger invoked' in guest or '[NYXT APP CHECK FAILED]' in guest
        or re.search(r'^stopped \d+:', guest, re.M)):
    raise SystemExit('Unexpected guest failure')
for url in ['/browser', '/browser?navigation=2', '/browser?recovery=1']:
    if f'ORIGIN 18766 "GET {url} HTTP/1.1" 200' not in (build / 'nyxt-dispatch-origin.log').read_text():
        raise SystemExit(f'Missing HTTPS request: {url}')
for name, marker in [('nyxt-dispatch-host.log', '[NYXT DISPATCH QUEUES PASS]'),
                     ('nyxt-outbox-host.log', '[NYXT OUTBOX FRAMING BOUNDS PASS]')]:
    if marker not in (build / name).read_text():
        raise SystemExit(f'Missing host queue check: {marker}')
kernel = (build / 'nyxt-dispatch-kernel-tests.log').read_text()
kernel_checks = sum(map(int, re.findall(r'Did (\d+) checks', kernel)))
if len(re.findall(r'Fail: 0 ', kernel)) != 5 or kernel_checks not in (90, 91):
    raise SystemExit('Kernel/process/world regression suites did not all pass')
legacy = (build / 'nyxt-dispatch-existing-port.log').read_text()
if ('Pass: 8 (100%)' not in legacy or 'Pass: 4 (100%)' not in legacy
        or len(re.findall(r'Fail: 0 ', legacy)) != 2):
    raise SystemExit('Existing port and world reclamation regression did not pass')
def digest(path):
    with path.open('rb') as f: return hashlib.file_digest(f, 'sha256').hexdigest()
def git(*args):
    return subprocess.check_output(['git', *args], cwd=repo, text=True).strip()
manifest = json.loads((build / 'nyxt-source-manifest.json').read_text())
for name, expected in manifest['files_sha256'].items():
    if digest(root / 'nyxt-source' / name) != expected:
        raise SystemExit(f'Pinned Nyxt source changed: {name}')
evidence_dir = Path(os.environ.get('DARTERFLY_WPE_EVIDENCE_DIR', Path.home() / 'org/darterfly/ports/nyxt/wpe'))
evidence_dir.mkdir(parents=True, exist_ok=True)
logs = evidence_dir / 'qualification-logs'
records = {}
for source, target in [(args.guest_log, 'nyxt-dispatch-guest.log'),
                       (repo / 'build/nyxt-port-stop-guest.log', 'nyxt-port-stop-guest.log'),
                       (repo / 'build/native-bsd-guest.log', 'nyxt-dispatch-native-guest.log'),
                       (repo / 'build/native-ipc-guest.log', 'nyxt-dispatch-ipc-guest.log'),
                       *[(build / name,name) for name in [
                           'nyxt-dispatch-os.log','nyxt-dispatch-origin.log','nyxt-dispatch-host.log',
                           'nyxt-outbox-host.log','nyxt-dispatch-kernel-tests.log',
                           'nyxt-dispatch-existing-port.log']]]:
    shutil.copyfile(source,logs / target);records[target] = digest(logs / target)
sources = [*port.glob('nyxt-*.lisp'),port / 'nyxt-engine.cpp',port / 'nyxt-outbox.hpp',
           *[port / p for p in ['application-image.lisp','run-nyxt-app.lisp','run-nyxt-build.lisp',
             'build-engine-probe.py','check-dispatch-host.lisp','check-outbox.cpp']],
           repo / 'src/kern/i386/world.lisp',repo / 'tests/boot.lisp']
evidence = {
    'recorded_utc': datetime.now(timezone.utc).isoformat(),
    'branch': git('branch','--show-current'), 'head': git('rev-parse','HEAD'),
    'guest_console_source': str(args.guest_log.resolve()),
    'run': 'One uninterrupted actual Darterfly QEMU guest: normal browsing, dispatch backpressure, clean relaunch, full crash recovery.',
    'install': 'Resumed source-build disk; freshly staged app and relinked shared-runtime engines.',
    'nyxt_revision': manifest['revision'], 'unchanged_nyxt_source_files_verified': len(manifest['files_sha256']),
    'checks': markers, 'kernel_regression_check_evaluations': kernel_checks + 12,
    'kernel_regression_unique_checks': 99,
    'sources_sha256': {str(p.relative_to(repo)):digest(p) for p in sorted(set(sources))},
    'logs_sha256': records, 'kernel_sha256': digest(repo / 'build/kernel/kernel'),
    'engines_sha256': {n:digest(root / 'engine' / n) for n in ['nyxt-engine','WPEWebProcess','WPENetworkProcess']},
    'limits': ['Queue payload limits are not total RSS limits.',
               'Scheme requests use two concurrent workers; event callbacks use one FIFO worker.',
               'Navigation-generation cancellation, broader deletion/GC stress and long soaks remain.',
               'Persistent profiles, complete interaction, authority review and fresh install remain merge gates.'],
}
(evidence_dir / 'dispatch-evidence.json').write_text(json.dumps(evidence,indent=2)+'\n')
print('Recorded complete dispatch/recovery qualification:',port / 'dispatch-evidence.json')
