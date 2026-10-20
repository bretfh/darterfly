#!/usr/bin/env python3
"""Build LLVM arithmetic compiler helpers against the shared Darterfly ABI."""
from pathlib import Path
import hashlib
import json
import subprocess

root = Path(__file__).resolve().parents[1]
source = Path('/gnu/store/9s6ip95sbxhfqx63c2nd7lz9xgl701kr-llvm-project-19.1.7-checkout')
builtins = source / 'compiler-rt/lib/builtins'
out = root / 'build/cxx/compiler-builtins'
out.mkdir(parents=True, exist_ok=True)
profile = Path((root/'build/wpe-assessment/build-tools.txt').read_text().splitlines()[0]).parent
names = ['fixdfti', 'floattidf', 'divti3', 'modti3', 'udivti3', 'umodti3', 'udivmodti4', 'clzti2', 'divdc3', 'muldc3']
objects = []
for name in names:
    obj = out / (name + '.o')
    subprocess.run([str(root/'ports/nyxt/wpe/target-cc.py'), '-c', '-O2',
                    '-ffreestanding', '-ffunction-sections', '-fdata-sections',
                    str(builtins/(name+'.c')), '-o', str(obj)], check=True)
    objects.append(obj)
(out/'libclang_rt.builtins.a').unlink(missing_ok=True)
subprocess.run(list(map(str, [profile/'llvm-ar', 'rcs',
                             out/'libclang_rt.builtins.a', *objects])), check=True)
(out/'provenance.json').write_text(json.dumps({
    'llvm_version': '19.1.7', 'source': str(source),
    'license': 'Apache-2.0 WITH LLVM-exception',
    'sources': {name+'.c': hashlib.sha256((builtins/(name+'.c')).read_bytes()).hexdigest()
                for name in names},
    'scope': 'Integer and complex arithmetic compiler helpers; no allocator, TLS or OS services'
}, indent=2)+'\n')
