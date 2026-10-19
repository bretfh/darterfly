#!/usr/bin/env python3
from pathlib import Path
import subprocess
r=Path(__file__).resolve().parents[3]
b=r/'build/wpe-assessment'; j=b/'jsc-target'
profile=Path((b/'build-tools.txt').read_text().splitlines()[0]).parent
subprocess.run(list(map(str,[r/'ports/nyxt/wpe/target-cc.py',
    '-c','-O2','-ffunction-sections','-fdata-sections',
    '-I'+str(j/'JavaScriptCore/Headers'),
    r/'ports/nyxt/wpe/jsc-probe.c','-o',b/'jsc-probe.o'])),check=True)
objects=sorted((j/'Source/JavaScriptCore/CMakeFiles/JavaScriptCoreJIT.dir').rglob('*.cpp.o'))
assert objects, 'Build JavaScriptCoreJIT object target first'
(j/'lib/libJavaScriptCoreJIT.a').unlink(missing_ok=True)
subprocess.run(list(map(str,[profile/'llvm-ar','rcs',j/'lib/libJavaScriptCoreJIT.a',*objects])),check=True)
libs=[j/'lib/libJavaScriptCore.a',j/'lib/libJavaScriptCoreJIT.a',j/'lib/libWTF.a',j/'lib/libbmalloc.a',
      b/'sysroot/lib/libicui18n.a',b/'sysroot/lib/libicuuc.a',
      b/'sysroot/lib/libicudata.a',
      r/'build/cxx/compiler-builtins/libclang_rt.builtins.a']
subprocess.run(list(map(str,[profile/'ld.lld','-r','--gc-sections',
    '--entry=main',b/'jsc-probe.o','--start-group',*libs,'--end-group',
    '-o',b/'jsc-guest.o'])),check=True)
