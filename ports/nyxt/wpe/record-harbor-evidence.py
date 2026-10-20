#!/usr/bin/env python3
"""Record Harbor/browser integration only after the complete guest runs pass."""
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess

repo = Path(__file__).resolve().parents[3]
build = repo / 'build/wpe-assessment'
root = Path((build / 'render-build-root.txt').read_text().strip())
output = Path(os.environ.get('DARTERFLY_WPE_EVIDENCE_DIR',
                             Path.home() / 'org/darterfly/ports/nyxt/wpe'))

def git(*args):
    return subprocess.check_output(['git', *args], cwd=repo, text=True).strip()

def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()

host = (build / 'nyxt-harbor-os.log').read_text()
guest = (build / 'nyxt-app-guest.log').read_text()
markers = [
    'NYXT BROWSER QUALIFICATION PASS', 'NYXT NORMAL APP WORLD PASS',
    'NYXT APP SINGLE INSTANCE PASS', 'NYXT HARBOR DISCOVERY PASS',
    'NYXT HARBOR RESIZE RESTORE PASS', 'NYXT APP QUIT PASS',
    'NYXT DISPATCH PRESENTATION PASS', 'NYXT DISPATCH ENGINE BACKPRESSURE PASS',
    'NYXT DISPATCH LATEST FRAME PASS', 'NYXT DISPATCH ORDERED RPC CALLBACKS PASS',
    'NYXT RECOVERY UI CLEANUP PASS', 'NYXT RECOVERY WEB CLEANUP PASS',
    'NYXT RECOVERY ENGINE BUDGET PASS', 'NYXT RECOVERY LISP CLEANUP PASS',
    'NYXT RECOVERY HUNG-ENGINE CLEANUP PASS', 'NYXT RECOVERY HUNG-APP BUDGET PASS',
    'NYXT RECOVERY WORKER CLEANUP PASS', 'NYXT RECOVERY NORMAL QUIT PASS',
]
for marker in markers:
    if not re.search(r'^(?:\* )?\[' + re.escape(marker) + r'\]\s*$', guest, re.M):
        raise SystemExit(f'Missing guest assertion: {marker}')
if '[NYXT COMBINED QUALIFICATION PASS]' not in host:
    raise SystemExit('Combined browser/recovery run did not complete')
if ('panic(' in guest or 'debugger invoked' in guest
        or re.search(r'^stopped \d+:', guest, re.M)):
    raise SystemExit('Guest kernel/supervisor failure')
regressions = (build / 'nyxt-harbor-regressions.log').read_text()
if ('[NYXT HARBOR OS REGRESSIONS PASS]' not in regressions
        or len(re.findall(r'Fail: 0 ', regressions)) != 7):
    raise SystemExit('Seven integrated OS regression tests have not all passed')
host_tests = (build / 'nyxt-harbor-master-host.log').read_text()
if not re.search(r'Pass: (\d+) \(100%\).*?Fail: 0 ', host_tests, re.S):
    raise SystemExit('Host regression suite did not pass')
if '[NYXT HARBOR TRANSPORT PASS]' not in host_tests:
    raise SystemExit('Harbor transport check did not pass')
origin = (build / 'nyxt-harbor-origin.log').read_text()
for url in ['/browser', '/browser?navigation=2', '/browser?recovery=1']:
    if f'ORIGIN 18766 "GET {url} HTTP/1.1" 200' not in origin:
        raise SystemExit(f'Missing verified HTTPS request: {url}')
manifest = json.loads((build / 'nyxt-source-manifest.json').read_text())
for name, expected in manifest['files_sha256'].items():
    if digest(root / 'nyxt-source' / name) != expected:
        raise SystemExit(f'Pinned Nyxt source changed: {name}')
if git('status', '--porcelain'):
    raise SystemExit('Commit the reviewed source before recording its evidence')
revision = git('rev-parse', 'HEAD')
logs = output / 'qualification-logs' / ('harbor-' + revision[:12])
logs.mkdir(parents=True, exist_ok=True)
recorded = {}
for name in ['nyxt-harbor-os.log', 'nyxt-app-guest.log', 'nyxt-harbor-origin.log',
             'nyxt-harbor-regressions.log', 'nyxt-harbor-master-host.log']:
    shutil.copyfile(build / name, logs / name)
    recorded[name] = digest(logs / name)
sources = git('ls-files').splitlines()
evidence = {
    'recorded_utc': datetime.now(timezone.utc).isoformat(),
    'head': revision,
    'master_included': git('rev-parse', 'master'),
    'installation': 'Resumed source/cache disk, copied and verified into a 4 GiB APFS disk; not a fresh-install qualification.',
    'nyxt_revision': manifest['revision'],
    'unchanged_nyxt_files': len(manifest['files_sha256']),
    'guest_checks': markers,
    'host_checks': int(re.search(r'Did (\d+) checks', host_tests)[1]),
    'os_regression_checks': sum(map(int, re.findall(r'Did (\d+) checks', regressions))),
    'logs_directory': str(logs), 'logs_sha256': recorded,
    'sources_sha256': {name: digest(repo / name) for name in sources
                      if name.startswith(('src/', 'tests/', 'ports/nyxt/wpe/'))},
    'kernel_sha256': digest(repo / 'build/kernel/kernel'),
    'core_sha256': digest(repo / 'build/darterfly.core'),
    'engines_sha256': {name: digest(root / 'engine' / name)
                      for name in ['nyxt-engine', 'WPEWebProcess', 'WPENetworkProcess']},
    'limits': ['WPE remains cross-built.',
               'Scrolling, clipboard, durable profiles, site coverage and long-duration resource measurements remain follow-up work.'],
}
(output / 'harbor-evidence.json').write_text(json.dumps(evidence, indent=2) + '\n')
print('Recorded', output / 'harbor-evidence.json')
