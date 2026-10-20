#!/usr/bin/env python3
"""Record measured engine/runtime checks separately from unfinished Nyxt work."""
import os
from datetime import datetime, timezone
import hashlib
import json
import re
from pathlib import Path
import shutil
import subprocess
r=Path(__file__).resolve().parents[3];p=r/'ports/nyxt/wpe';b=r/'build/wpe-assessment'
w=Path((b/'render-build-root.txt').read_text().strip())
evidence_dir = Path(os.environ.get('DARTERFLY_WPE_EVIDENCE_DIR', Path.home() / 'org/darterfly/ports/nyxt/wpe'))
evidence_dir.mkdir(parents=True, exist_ok=True)
logs = evidence_dir / 'qualification-logs';logs.mkdir(exist_ok=True)
def digest(path):
    h=hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda:stream.read(1048576),b''):h.update(block)
    return h.hexdigest()
checks={
    'engine-https-world':(b/'engine-https-guest.log',['ENGINE PASS http-page','ENGINE PASS https-verified','ENGINE PASS https-recovery','ENGINE PASS COMPLETE','[ENGINE-WORLD NORMAL-INIT T]','[ENGINE-WORLD CHILDREN-CLEAN T]','[ENGINE-WORLD CHILDREN-REAPED T]','[ENGINE-WORLD STATUS 0]']),
    'engine-https-origin':(b/'engine-https-host.log',['ENGINE ORIGIN PASS: HTTP, TLS 1.3 and TLS 1.2 resources served']),
    'engine-shared-runtime-host':(b/'engine-shared-runtime-host.log',['Pass: 74 (100%)','Pass: 10 (100%)','Fail: 0']),
    'engine-local-page-world':(b/'engine-local-page-guest.log',['ENGINE PASS javascript-dom','ENGINE PASS html-css-js-pixels','ENGINE PASS COMPLETE','[ENGINE-WORLD STATUS 0]','[ENGINE-WORLD SUPERVISOR 42]']),
    'native-linker-host':(b/'engine-linker-host.log',['Pass: 10 (100%)','Fail: 0']),
    'cxx-filesystem-world':(r/'build/native-cxx-guest.log',['[CXX FILESYSTEM PASS]','[CXX ISOLATION PASS]','[CXX CLEAN PASS]']),
    'cxx-filesystem-host':(b/'engine-cxx-guest-host.log',['Pass: 18 (100%)','Fail: 0']),
    'native-bsd-host':(b/'engine-native-host.log',['Pass: 54 (100%)','Fail: 0']),
    'render-world':(b/'render-guest.log',['RENDER PASS COMPLETE','[RENDER-WORLD STATUS 0]','[RENDER-WORLD SUPERVISOR 42]']),
    'skia-wpe-platform-world':(b/'platform-guest.log',['PLATFORM PASS skia-antialiasing','PLATFORM PASS COMPLETE','[PLATFORM-WORLD STATUS 0]','[PLATFORM-WORLD SUPERVISOR 42]']),
    'render-math-host':(b/'render-float-host.log',['FLOAT PRIMITIVES PASS','1444 remainder edges', 'ERFF PASS 1100001', 'ELEMENTARY PASS']),
    'render-ipc-world':(r/'build/native-ipc-guest.log',['[NATIVE-IPC SHM-NAMES PASS]','[NATIVE-IPC SHARED-PAGES PASS]','[NATIVE-IPC ALIVE PASS]']),
    'render-ipc-host':(b/'render-ipc-host.log',['Pass: 14 (100%)','Fail: 0']),
    'render-loader-host':(b/'render-native-dl-host.log',['Pass: 32 (100%)','Fail: 0']),
}
recorded={}
for name,(source,markers) in checks.items():
    content=source.read_text()
    if not all(marker in content for marker in markers):
        raise SystemExit('Incomplete check: '+str(source))
    if name.endswith('world') and re.search(r'\b(?:FAIL|WARNING|CRITICAL)\b',content):
        raise SystemExit('Unexpected diagnostic: '+str(source))
    dest=logs/(name+'.log');shutil.copyfile(source,dest)
    recorded[name]={'path':str(dest.relative_to(p)),'sha256':digest(dest),'completed_log_mtime_utc':datetime.fromtimestamp(source.stat().st_mtime,timezone.utc).isoformat()}
files=set((r/'licenses').glob('*COPYRIGHT'))
for base in ['src/libsa','src/bsd','src/vfs','src/low','src/link','src/cc']:
    files.update(x for x in (r/base).rglob('*') if x.is_file())
for pattern in ['*.py','*.sh','*.c','*.inc','*.cpp','*.lisp','*.conf','patches/*','licenses/*']:
    files.update(x for x in p.glob(pattern) if x.is_file())
files.update(r/name for name in ['darterfly.asd','tests/libsa-float-host.c',
    'tools/check-libsa-float.sh','tests/native-ipc-probe.c','tests/native-ipc.lisp',
    'tests/native-dl-probe.cpp','tests/native-dl.lisp','tests/native-cxx.lisp',
    'tests/native-cxx-probe.cpp','tests/native.lisp','tools/build-cxx-runtime.py'])
artifacts=[b/'render-guest.o',b/'platform-guest.o',w/'webkit-target/lib/libSkia.a',
           r/'build/cxx/runtime.o',r/'build/cxx/crt0.o',
           *[w/'engine'/name for name in ['engine-probe','WPEWebProcess','WPENetworkProcess']]]
artifacts+=sorted((b/'sysroot/lib').glob('*.a'))
data={
    'recorded_utc':datetime.now(timezone.utc).isoformat(),
    'branch':subprocess.check_output(['git','branch','--show-current'],cwd=r,text=True).strip(),
    'head':subprocess.check_output(['git','rev-parse','HEAD'],cwd=r,text=True).strip(),
    'state':'Uncommitted worktree; existing staged D2 merge preserved.',
    'qualified':'Full WebKit local, HTTP and verified TLS 1.2/1.3 HTML/CSS/JavaScript rendered to CPU pixels; sixteen invalid-certificate navigations rejected, valid HTTPS recovered, normal init reaped engine children; rendering dependencies, C++ filesystem, shared memory and resident loader lookup in isolated native worlds.',
    'not_yet_qualified':['Darterfly window presentation','Nyxt renderer','Persistent browser database'],
    'math':'400000 random float cases and 400000 random double remainder cases across four rounding modes, 1764 stepping/min/max/rounding edges, 37044 FMA edges, 1444 remainder edges; 1100001 erff inputs within 2 ULP under nearest rounding; logf/exp2f each 100021 inputs within 2 ULP under nearest rounding; numerical results only. Min/max uses C99 missing-data NaN semantics, not glibc signaling-NaN propagation.',
    'runtime':'One shared Low libsa implementation, BSD services and existing allocator/TLS; no guest Linux runtime.',
    'logs':recorded,
    'guix_origins':json.loads((p/'render-source-origins.json').read_text()),
    'khronos_header_origins':json.loads((p/'render-header-origins.json').read_text()),
    'inputs_sha256':{str(x.relative_to(r)):digest(x) for x in sorted(files)},
    'artifacts_sha256':{str(x):digest(x) for x in artifacts},
}
(evidence_dir / 'render-evidence.json').write_text(json.dumps(data,indent=2)+'\n')
print('Recorded completed rendering checks:',p/'render-evidence.json')
