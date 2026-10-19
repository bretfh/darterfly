#!/usr/bin/env python3
"""Stage pinned Nyxt and its existing source dependencies, without host binaries."""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
r = Path(__file__).resolve().parents[3]
b = r/'build/wpe-assessment'
w = Path((b/'render-build-root.txt').read_text().strip())
source = Path(sys.argv[1] if len(sys.argv)>1 else '/tmp/darterfly-cef-reproduction/nyxt')
revision = subprocess.check_output(['git','rev-parse','HEAD'],cwd=source,text=True).strip()
if revision != 'cfa068ea781fe4866ae435c2950c00c5ec51cfee':
    raise SystemExit('Expected the already-qualified pinned Nyxt source checkout')
target = w/'nyxt-source'
skip_dirs = {'.git','node_modules','__pycache__','.cache'}
skip_suffixes = {'.fasl','.o','.so','.a','.pyc','.core'}
records = {}
for path in sorted(source.rglob('*')):
    rel = path.relative_to(source)
    if any(part in skip_dirs for part in rel.parts) or not path.is_file():
        continue
    if path.name in {'.git','nyxt'} or path.suffix in skip_suffixes:
        continue
    data = path.read_bytes()
    if data.startswith(b'\x7fELF'):
        continue
    dest = target/rel
    dest.parent.mkdir(parents=True,exist_ok=True)
    if not dest.exists() or dest.read_bytes()!=data:
        shutil.copyfile(path,dest)
    records[str(rel)] = hashlib.sha256(data).hexdigest()
record = {'source':str(source),'revision':revision,'staged':str(target),
          'submodules':subprocess.check_output(['git','submodule','status','--recursive'],cwd=source,text=True).splitlines(),
          'files_sha256':records}
(b/'nyxt-source-manifest.json').write_text(json.dumps(record,indent=2)+'\n')
print('Staged',len(records),'source files:',target)
