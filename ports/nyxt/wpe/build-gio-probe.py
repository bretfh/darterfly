#!/usr/bin/env python3
from pathlib import Path
import subprocess
r=Path(__file__).resolve().parents[3]
b=r/'build/wpe-assessment'
g=b/'glib-gio-target';src=b/'glib-2.86.0'
profile=Path((b/'build-tools.txt').read_text().splitlines()[0]).parent
cc=r/'ports/nyxt/wpe/target-cc.py'
args=[cc,'-c','-O2','-ffunction-sections','-fdata-sections',
      '-DGLIB_STATIC_COMPILATION','-DGOBJECT_STATIC_COMPILATION','-DGIO_STATIC_COMPILATION',
      '-I'+str(src),'-I'+str(src/'glib'),'-I'+str(g),'-I'+str(g/'glib'),'-I'+str(src/'gmodule'),'-I'+str(src/'gio'),'-I'+str(g/'gio'),
      r/'ports/nyxt/wpe/gio-probe.c','-o',b/'gio-probe.o']
subprocess.run(list(map(str,args)),check=True)
libs=[g/'gio/libgio-2.0.a',g/'gmodule/libgmodule-2.0.a',g/'gobject/libgobject-2.0.a',g/'glib/libglib-2.0.a',
      g/'subprojects/proxy-libintl/libintl.a',
      b/'sysroot/lib/libpcre2-8.a',b/'sysroot/lib/libffi.a',
      b/'sysroot/lib/libiconv.a',b/'sysroot/lib/libz.a']
subprocess.run(list(map(str,[profile/'ld.lld','-r','--gc-sections',
    '--entry=main',b/'gio-probe.o','--start-group',*libs,'--end-group',
    '-o',b/'gio-guest.o'])),check=True)
