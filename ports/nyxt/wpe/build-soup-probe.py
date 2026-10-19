#!/usr/bin/env python3
from pathlib import Path
import subprocess
r=Path(__file__).resolve().parents[3]
b=r/'build/wpe-assessment'
g=b/'glib-gio-target';src=b/'glib-2.86.0'
profile=Path((b/'build-tools.txt').read_text().splitlines()[0]).parent
cc=r/'ports/nyxt/wpe/target-cc.py'
args=[cc,'-I'+str(b/'sysroot/include/libsoup-3.0'),'-c','-O2','-ffunction-sections','-fdata-sections',
      '-DGLIB_STATIC_COMPILATION','-DGOBJECT_STATIC_COMPILATION','-DGIO_STATIC_COMPILATION',
      '-I'+str(src),'-I'+str(src/'glib'),'-I'+str(g),'-I'+str(g/'glib'),'-I'+str(src/'gmodule'),'-I'+str(src/'gio'),'-I'+str(g/'gio'),
      r/'ports/nyxt/wpe/soup-probe.c','-o',b/'soup-probe.o']
subprocess.run(list(map(str,args)),check=True)
subprocess.run(list(map(str,[*args[:-3],
    r/'ports/nyxt/wpe/static-openssl.c','-o',b/'static-openssl.o'])),check=True)
libs=[b/'sysroot/lib/libsoup-3.0.a',b/'sysroot/lib/libnghttp2.a',
      b/'sysroot/lib/libsqlite3.a',b/'sysroot/lib/libpsl.a',
      b/'sysroot/lib/libicuuc.a',b/'sysroot/lib/libicudata.a',
      r/'build/cxx/compiler-builtins/libclang_rt.builtins.a',b/'glib-networking-target/tls/openssl/libgioopenssl.a',
      b/'sysroot/lib/libssl.a',b/'sysroot/lib/libcrypto.a',g/'gio/libgio-2.0.a',g/'gmodule/libgmodule-2.0.a',g/'gobject/libgobject-2.0.a',g/'glib/libglib-2.0.a',
      g/'subprojects/proxy-libintl/libintl.a',
      b/'sysroot/lib/libpcre2-8.a',b/'sysroot/lib/libffi.a',
      b/'sysroot/lib/libiconv.a',b/'sysroot/lib/libz.a']
subprocess.run(list(map(str,[profile/'ld.lld','-r','--gc-sections',
    '--entry=main',b/'soup-probe.o',b/'static-openssl.o','--start-group',*libs,'--end-group',
    '-o',b/'soup-guest.o'])),check=True)
