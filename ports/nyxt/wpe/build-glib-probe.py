#!/usr/bin/env python3
from pathlib import Path
import subprocess
r=Path(__file__).resolve().parents[3]
b=r/'build/wpe-assessment'
g=b/'glib-target';src=b/'glib-2.86.0'
profile=Path((b/'build-tools.txt').read_text().splitlines()[0]).parent
cc=r/'ports/nyxt/wpe/target-cc.py'
args=[cc,'-c','-O2','-ffunction-sections','-fdata-sections',
      '-DGLIB_STATIC_COMPILATION','-DGOBJECT_STATIC_COMPILATION',
      '-I'+str(src),'-I'+str(src/'glib'),'-I'+str(g),'-I'+str(g/'glib'),
      r/'ports/nyxt/wpe/glib-probe.c','-o',b/'glib-probe.o']
subprocess.run(list(map(str,args)),check=True)
libs=[g/'gobject/libgobject-2.0.a',g/'glib/libglib-2.0.a',
      g/'subprojects/proxy-libintl/libintl.a',
      b/'sysroot/lib/libpcre2-8.a',b/'sysroot/lib/libffi.a',
      b/'sysroot/lib/libiconv.a']
subprocess.run(list(map(str,[profile/'ld.lld','-r','--gc-sections',
    '--entry=main',b/'glib-probe.o','--start-group',*libs,'--end-group',
    '-o',b/'glib-guest.o'])),check=True)
