#!/usr/bin/env python3
"""Keep crash-recovery evidence separate from the historical browser records."""
from datetime import datetime, timezone
from pathlib import Path
import hashlib
import json
import re
import shutil
import subprocess

repo = Path(__file__).resolve().parents[3]
port = repo / 'ports/nyxt/wpe'
build = repo / 'build/wpe-assessment'
root = Path((build / 'render-build-root.txt').read_text().strip())
guest = (build / 'nyxt-app-guest.log').read_text()
host = (build / 'nyxt-recovery-host.log').read_text()
markers = [
    '[NYXT NORMAL APP WORLD PASS]', '[NYXT APP SINGLE INSTANCE PASS]',
    '[NYXT BROWSER HTTPS PAGE PASS]', '[NYXT BROWSER JAVASCRIPT PASS]',
    '[NYXT BROWSER TRUSTED LISP CALLBACK PASS]',
    '[NYXT BROWSER WEB CALLBACK DENIED PASS]',
    '[NYXT BROWSER TRUSTED INPUT PASS]', '[NYXT BROWSER COMMAND NAVIGATION PASS]',
    '[NYXT BROWSER LATE PROMPT UPDATE PASS]', '[NYXT APP CLEANUP PASS]',
    '[NYXT APP RELAUNCH PASS]', '[NYXT APP QUIT PASS]',
    '[NYXT RECOVERY UI CLEANUP PASS]', '[NYXT RECOVERY WEB CLEANUP PASS]',
    '[NYXT RECOVERY ENGINE BUDGET PASS]', '[NYXT RECOVERY LISP CLEANUP PASS]',
    '[NYXT RECOVERY HUNG-ENGINE CLEANUP PASS]',
    '[NYXT RECOVERY HUNG-APP BUDGET PASS]', '[NYXT RECOVERY WORKER CLEANUP PASS]',
    '[NYXT RECOVERY NORMAL QUIT PASS]',
]
for marker in markers:
    if not re.search(r'^(?:\* )?' + re.escape(marker) + r'\s*$', guest, re.M):
        raise SystemExit(f'Missing guest assertion: {marker}')
for marker in ['[NYXT APP QUALIFICATION PASS]',
               '[NYXT RECOVERY HTTPS JAVASCRIPT PASS]',
               '[NYXT CRASH QUALIFICATION PASS]']:
    if marker not in host:
        raise SystemExit(f'Missing host assertion: {marker}')
if 'debugger invoked' in guest or '[NYXT APP CHECK FAILED]' in guest:
    raise SystemExit('Unexpected guest failure')
origin = (build / 'nyxt-recovery-origin.log').read_text()
for url in ['/browser', '/browser?navigation=2', '/browser?recovery=1']:
    if f'ORIGIN 18766 "GET {url} HTTP/1.1" 200' not in origin:
        raise SystemExit(f'Missing independent HTTPS origin evidence: {url}')
bounds = (build / 'nyxt-recovery-bounds.log').read_text()
for marker in ['[NYXT RECOVERY POLICY PASS]', '[NYXT RECOVERY TRANSPORT BOUNDS PASS]']:
    if marker not in bounds:
        raise SystemExit(f'Missing bounds assertion: {marker}')
checks = (build / 'nyxt-recovery-host-tests.log').read_text()
if len(re.findall(r'Fail: 0 ', checks)) != 3:
    raise SystemExit('Existing host regression suites did not all pass')

native = (build / 'nyxt-recovery-native-tests.log').read_text()
native_guest = (repo / 'build/native-bsd-guest.log').read_text()
if not re.search(r'Pass: 47 \(100%\)', native) or 'Fail: 0 ' not in native:
    raise SystemExit('Native process regression suite did not pass')
for name in ['KILL-PAUSED-THREADS', 'KILL-CHURN-THREADS', 'PTHREAD-RECLAIM', 'MAP-COALESCE-EXHAUSTION']:
    if f'[BSD-NATIVE {name} PASS]' not in native_guest:
        raise SystemExit(f'Missing native termination regression: {name}')

kernel_checks = (build / 'nyxt-recovery-kernel-tests.log').read_text()
for name in ['NATIVE-DYNAMIC-LOADING-ON-DARTERFLY', 'NATIVE-IPC-ON-DARTERFLY', 'THREADS-ON-DARTERFLY',
             'SMP-ON-DARTERFLY', 'INIT-KEEPS-WORLD-JOBS-ALIVE-AND-QUARANTINES',
             'AN-APP-IN-ITS-OWN-WORLD-OPENS-A-WINDOW-AND-DYING-TAKES-IT-AWAY']:
    if f'Running test {name} ' not in kernel_checks:
        raise SystemExit(f'Missing OS regression: {name}')
if len(re.findall(r'Fail: 0 ', kernel_checks)) != 6:
    raise SystemExit('OS regression suites did not all pass')

def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()

def git(*args):
    return subprocess.check_output(['git', *args], cwd=repo, text=True).strip()

manifest = json.loads((build / 'nyxt-source-manifest.json').read_text())
for name, expected in manifest['files_sha256'].items():
    if digest(root / 'nyxt-source' / name) != expected:
        raise SystemExit(f'Pinned Nyxt source changed: {name}')
logs = port / 'qualification-logs'
records = {}
for source, target in [
    ('nyxt-app-guest.log', 'nyxt-recovery-guest.log'),
    *[(name, name) for name in ['nyxt-recovery-host.log', 'nyxt-recovery-origin.log',
                              'nyxt-recovery-bounds.log', 'nyxt-recovery-host-tests.log',
                              'nyxt-recovery-native-tests.log', 'nyxt-recovery-kernel-tests.log']]]:
    shutil.copyfile(build / source, logs / target)
    records[target] = digest(logs / target)
shutil.copyfile(repo / 'build/native-bsd-guest.log', logs / 'nyxt-recovery-native-guest.log')
records['nyxt-recovery-native-guest.log'] = digest(logs / 'nyxt-recovery-native-guest.log')
shutil.copyfile(repo / 'build/native-ipc-guest.log', logs / 'nyxt-recovery-ipc-guest.log')
records['nyxt-recovery-ipc-guest.log'] = digest(logs / 'nyxt-recovery-ipc-guest.log')
shutil.copyfile(repo / 'build/native-dl-guest.log', logs / 'nyxt-recovery-dl-guest.log')
records['nyxt-recovery-dl-guest.log'] = digest(logs / 'nyxt-recovery-dl-guest.log')
sources = [*port.glob('nyxt-*.lisp'), port / 'nyxt-engine.cpp',
           port / 'run-nyxt-app.lisp', port / 'run-nyxt-app.sh',
           port / 'check-recovery-host.lisp', port / 'application-image.lisp',
           port / 'build-webkit.py',
           port / 'patches/wpe-darterfly-process-failure.patch',
           repo / 'src/apps/open.lisp', repo / 'src/apps/nyxt.lisp',
           repo / 'src/init/init.lisp', repo / 'tests/init.lisp',
           repo / 'src/libsa/pthread.lisp', repo / 'src/libsa/start.lisp',
           repo / 'src/kern/i386/sched.lisp', repo / 'src/kern/i386/trap.lisp',
           repo / 'src/kern/i386/vm-map.lisp', repo / 'src/kern/i386/world.lisp',
           repo / 'src/bsd/dev/i386/systemcalls.lisp',
           repo / 'tests/native.lisp', repo / 'tests/native-bsd-probe.c',
           repo / 'tests/native-bsd-guest.lisp']
evidence = {
    'recorded_utc': datetime.now(timezone.utc).isoformat(),
    'branch': git('branch', '--show-current'), 'head': git('rev-parse', 'HEAD'),
    'nyxt_revision': manifest['revision'], 'webkit_version': '2.54.1',
    'unchanged_nyxt_source_files_verified': len(manifest['files_sha256']),
    'run': 'Actual Darterfly QEMU: ordinary init/Dock/app worlds/WindowServer, shared libsa, 8 GiB guest.',
    'install': 'Resumed source-build disk with cached dependencies; newly staged application and relinked native engines.',
    'policy': 'Init restart-on-crash; third failure within 600 seconds stops retries. Manual launch resets budget; clean exit does not restart.',
    'injections': ['SIGKILL UI process', 'SIGKILL WebProcess', 'SIGKILL NetworkProcess',
                   'Stop Nyxt Lisp world', 'Pause UI process during liveness RPC',
                   'Pause Nyxt Lisp world to exercise external init health check',
                   'Unhandled upstream Bordeaux worker error'],
    'checks': markers,
    'host_regression_checks': sum(map(int, re.findall(r'Did (\d+) checks', checks))),
    'native_regression_checks': 47,
    'kernel_regression_checks': sum(map(int, re.findall(r'Did (\d+) checks', kernel_checks))),
    'vm_map_regression': '4096 page protection round trips; map exhaustion returns ENOMEM atomically; reclaim and allocate again.',
    'pthread_reclamation': '2048 owned-stack create/join cycles; 32 borrowed-stack cycles retain caller ownership; dynamic C++ TLS/destructor regressions.',
    'native_termination_stress': '24 kills: sleeping and creating/joining threads, half paused before kill; wait status and world reclamation checked.',
    'host_bounds': 'Policy transitions; blocked writer; partial header/body; cancellation; contested writer lock.',
    'logs_sha256': records,
    'source_sha256': {str(p.relative_to(repo)): digest(p) for p in sorted(set(sources))},
    'kernel_sha256': digest(repo / 'build/kernel/kernel'),
    'engine_sha256': {name: digest(root / 'engine' / name)
                     for name in ['nyxt-engine', 'WPEWebProcess', 'WPENetworkProcess']},
    'limits': ['Whole-session restart; unsaved tabs/forms are not restored.',
               'Fresh source build/install not qualified by this run.',
               'Frame coalescing and callback queue bounds remain separate work.',
               'Persistent profiles, complete interaction, and wider-site coverage remain merge gates.'],
}
(port / 'recovery-evidence.json').write_text(json.dumps(evidence, indent=2) + '\n')
print('Recorded actual-OS recovery:', port / 'recovery-evidence.json')
