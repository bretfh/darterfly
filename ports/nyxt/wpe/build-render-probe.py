#!/usr/bin/env python3
from pathlib import Path
import subprocess
r=Path(__file__).resolve().parents[3]
b=r/'build/wpe-assessment'; p=b/'sysroot'
profile=Path((b/'build-tools.txt').read_text().splitlines()[0]).parent
cc=r/'ports/nyxt/wpe/target-cc.py'
subprocess.run(list(map(str,[cc,'-c','-O2','-fno-builtin','-ffunction-sections','-fdata-sections',
    '-I'+str(p/'include/freetype2'),'-I'+str(p/'include/harfbuzz'),'-I'+str(p/'include/libxml2'),
    r/'ports/nyxt/wpe/render-probe.c','-o',b/'render-probe.o'])),check=True)
libs=['fontconfig','harfbuzz','freetype','png16','jpeg','webp','sharpyuv','xml2',
      'expat','gcrypt','gpg-error','tasn1','xkbcommon','z','iconv']
subprocess.run(list(map(str,[profile/'ld.lld','-r','--gc-sections','--entry=main',
    b/'render-probe.o','--start-group',*[p/'lib'/('lib'+n+'.a') for n in libs],
    r/'build/cxx/compiler-builtins/libclang_rt.builtins.a','--end-group',
    '-o',b/'render-guest.o'])),check=True)
