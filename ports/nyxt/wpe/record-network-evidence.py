#!/usr/bin/env python3
"""Save completed native networking qualification and its exact inputs."""
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

root = Path(__file__).resolve().parents[3]
port = root/'ports/nyxt/wpe'
build = root/'build/wpe-assessment'
logs = port/'qualification-logs'
def digest(path):
    h=hashlib.sha256()
    with path.open('rb') as f:
        for block in iter(lambda: f.read(1024*1024),b''): h.update(block)
    return h.hexdigest()

tests = {
    'gio-network': ('gio-guest.log', '[GIO-WORLD STATUS 0]', 'GIO PASS '),
    'tls-network': ('tls-guest.log', '[TLS-WORLD STATUS 0]', 'TLS PASS '),
    'soup-network': ('soup-guest.log', '[SOUP-WORLD STATUS 0]', 'SOUP PASS '),
    'network-primitives': ('network-primitives-host.log','NETWORK PRIMITIVES PASS',None),
    'network-host': ('network-host.log','Pass: 55 (100%)','Fail: 0'),
    'network-native-bsd': ('network-native-bsd-host.log','Pass: 43 (100%)','Fail: 0'),
}
recorded_logs={}
for name,(source,marker,other) in tests.items():
    content=(build/source).read_text()
    if marker not in content or (other and other not in content):
        raise SystemExit(f'Incomplete qualification: {source}')
    if name in ('gio-network','tls-network','soup-network'):
        if 'WARNING' in content or 'CRITICAL' in content:
            raise SystemExit(f'Runtime warnings in {source}')
    dest=logs/(name+'.log')
    shutil.copyfile(build/source,dest)
    recorded_logs[name]={'path':str(dest.relative_to(port)),'sha256':digest(dest)}

sources={}
for line in (build/'http-sources.txt').read_text().splitlines()[:6]:
    path=Path(line)
    sources[path.name]={'guix_store_path':str(path),'sha256':digest(path)}

files=set()
for base in ['src/libsa','src/bsd','src/net','src/vfs','src/low','src/link','src/cc']:
    files.update(p for p in (root/base).rglob('*') if p.is_file())
files.add(root/'darterfly.asd')
files.update([root/'tests/libsa-network-host.c',root/'tools/check-libsa-network.sh'])
for pattern in ['*.py','*.sh','*.c','*.lisp','*.conf','patches/*']:
    files.update(port.glob(pattern))
artifacts=['gio-guest.o','tls-guest.o','soup-guest.o','sysroot/lib/libssl.a',
           'sysroot/lib/libcrypto.a','sysroot/lib/libsoup-3.0.a',
           'glib-networking-target/tls/openssl/libgioopenssl.a']
ca=Path(os.environ.get('DARTER_PUBLIC_CA_BUNDLE','/etc/ssl/certs/ca-certificates.crt'))
result={
    'recorded_utc':datetime.now(timezone.utc).isoformat(),
    'branch':subprocess.check_output(['git','branch','--show-current'],cwd=root,text=True).strip(),
    'head':subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip(),
    'state':'Uncommitted worktree; existing staged D2 merge preserved. Hashes identify tested sources.',
    'result':'Native GIO, OpenSSL/glib-networking TLS and libsoup execute in isolated Darterfly worlds; verified public HTTPS fetch.',
    'configuration':{
        'runtime':'Shared Low libsa and BSD services; no guest Linux/macOS runtime',
        'tls':'OpenSSL 3.5.7 static portable C, pthreads, /dev/urandom; glib-networking 2.80.1 static OpenSSL backend',
        'http':'libsoup 3.6.5, nghttp2 1.58.0, libpsl 0.21.5 with ICU 78.2; Brotli, NTLM and GSSAPI disabled',
        'sqlite':'3.53.1 built, persistent database behavior not qualified',
    },
    'checks':{
        'tls_versions':['TLS1.2','TLS1.3'],
        'certificate_rejections':['wrong hostname','unknown CA','expired','not yet valid'],
        'http':['HTTP/1.1','HTTP/2','HTTPS','async','redirects','memory cookies','gzip','chunked','POST','public example.com'],
        'network_host_assertions':55,'native_bsd_assertions':43,
        'address_roundtrips':10000,'glob_comparisons':50000,
    },
    'public_ca_bundle':{'source':str(ca.resolve()),'sha256':digest(ca)},
    'logs':recorded_logs,
    'guix_origins':sources,
    'inputs_sha256':{str(p.relative_to(root)):digest(p) for p in sorted(files)},
    'artifacts_sha256':{p:digest(build/p) for p in artifacts},
    'native_runtime_sha256':{p:digest(root/p) for p in
                              ['build/cxx/runtime.o','build/cxx/crt0.o']},
}
(port/'network-evidence.json').write_text(json.dumps(result,indent=2)+'\n')
print('Recorded native HTTP/TLS qualification:',port/'network-evidence.json')
