#!/usr/bin/env python3
"""Build the upstream HTTP/TLS libraries against Darterfly's shared libsa."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
r = Path(__file__).resolve().parents[3]
b = r/'build/wpe-assessment'
p = b/'sysroot'
profile = Path((b/'build-tools.txt').read_text().splitlines()[0]).parent
cc = r/'ports/nyxt/wpe/target-cc.py'
env = dict(os.environ)
for key in ['CPATH', 'C_INCLUDE_PATH', 'CPLUS_INCLUDE_PATH', 'LIBRARY_PATH']:
    env.pop(key, None)
env.update(PATH=str(profile)+':'+env['PATH'], CC=str(cc),
           AR=str(profile/'llvm-ar'), RANLIB=str(profile/'llvm-ranlib'),
           PKG_CONFIG_LIBDIR=str(p/'lib/pkgconfig'), PKG_CONFIG_PATH='')
def run(args, cwd=r):
    print('+', ' '.join(map(str, args)), flush=True)
    subprocess.run(list(map(str, args)), cwd=cwd, env=env, check=True)
def stage_meson(out):
    # Install only built static libraries, public headers and pkg-config data.
    # Do not build or run target-side CLI tools on the build host.
    installed = json.loads((out/'meson-info/intro-installed.json').read_text())
    for source, dest in installed.items():
        source, dest = Path(source), Path(dest)
        if 'girepository' in source.parts or dest.name.startswith('girepository-'):
            continue  # Introspection is not part of this qualification.
        if dest.suffix in ('.a', '.h', '.pc'):
            if not dest.is_relative_to(p):
                raise RuntimeError(f'Unexpected install destination: {dest}')
            if not source.exists():
                if dest.name == 'libgthread-2.0.a':
                    continue  # Legacy library, not a dependency of this build.
                raise FileNotFoundError(source)
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, dest)
which = sys.argv[1]
if which == 'gio-install':
    stage_meson(b/'glib-gio-target')
elif which == 'openssl':
    src = b/'openssl-3.5.7'
    out = b/'openssl-target'
    out.mkdir(exist_ok=True)
    config = r/'ports/nyxt/wpe/openssl-darterfly.conf'
    target = src/'Configurations/50-darterfly.conf'
    changed = not target.exists() or target.read_bytes() != config.read_bytes()
    if changed:
        shutil.copyfile(config, target)
    if changed or not (out/'Makefile').exists():
        run(['perl', src/'Configure', 'darterfly-x86_64',
             '--prefix='+str(p), '--openssldir=/etc/ssl', '--libdir=lib',
             '--with-rand-seed=devrandom', 'no-shared', 'no-module',
             'no-asm', 'no-tests', 'no-apps', 'no-docs', 'no-async',
             'no-engine', 'no-dso', 'no-quic'], cwd=out)
    run(['make', '-j8', 'build_libs'], cwd=out)
    run(['make', 'install_dev'], cwd=out)
elif which == 'glib-networking':
    run([sys.executable, r/'ports/nyxt/wpe/apply-patches.py',
         b/'glib-networking-2.80.1', 'glib-networking-static-install.patch'])
    out = b/'glib-networking-target'
    run([profile/'meson', 'setup', out, b/'glib-networking-2.80.1',
         '--cross-file', b/'glib-cross.ini', '--prefix', p,
         '-Dgnutls=disabled', '-Dopenssl=enabled', '-Dlibproxy=disabled',
         '-Dgnome_proxy=disabled', '-Denvironment_proxy=disabled', '-Db_staticpic=true',
         '--wrap-mode=nodownload'])
    run([profile/'ninja', '-C', out, '-j8', 'tls/openssl/libgioopenssl.a'])
    # Upstream also declares shared modules; only the static archive is built.
    dest = p/'lib/gio/modules/libgioopenssl.a'
    dest.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(out/'tls/openssl/libgioopenssl.a', dest)
elif which == 'nghttp2':
    out = b/'nghttp2-target'
    run([profile/'cmake', '-S', b/'nghttp2-1.58.0', '-B', out, '-G', 'Ninja',
         '-DCMAKE_POLICY_VERSION_MINIMUM=3.5', '-DCMAKE_SYSTEM_NAME=Generic',
         '-DCMAKE_C_COMPILER='+str(cc), '-DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY',
         '-DCMAKE_INSTALL_PREFIX='+str(p), '-DCMAKE_BUILD_TYPE=MinSizeRel',
         '-DENABLE_LIB_ONLY=ON', '-DENABLE_STATIC_LIB=ON', '-DENABLE_SHARED_LIB=OFF',
         '-DENABLE_DOC=OFF', '-DBUILD_TESTING=OFF'])
    run([profile/'cmake', '--build', out, '-j8'])
    run([profile/'cmake', '--install', out])
elif which == 'sqlite':
    src = b/'sqlite-autoconf-3530100'
    out = b/'sqlite-target'
    out.mkdir(exist_ok=True)
    run([cc, '-c', '-O2', '-ffunction-sections', '-fdata-sections',
         '-DSQLITE_THREADSAFE=1', '-DSQLITE_OMIT_LOAD_EXTENSION',
         src/'sqlite3.c', '-o', out/'sqlite3.o'])
    run([profile/'llvm-ar', 'rcs', p/'lib/libsqlite3.a', out/'sqlite3.o'])
    for name in ['sqlite3.h', 'sqlite3ext.h']:
        shutil.copyfile(src/name, p/'include'/name)
    (p/'lib/pkgconfig/sqlite3.pc').write_text(f"""prefix={p}
libdir=${{prefix}}/lib
includedir=${{prefix}}/include
Name: SQLite
Description: SQLite amalgamation for shared libsa
Version: 3.53.1
Libs: -L${{libdir}} -lsqlite3
Cflags: -I${{includedir}}
""")
elif which == 'libpsl':
    # Publish the already built shared C++ runtime under its conventional
    # link name, so Meson's compiler detection can link a real libc++.
    objects = [(r/'build/cxx'/name) for name in
               (r/'build/cxx/objects.list').read_text().splitlines()]
    run([profile/'llvm-ar', 'rcs', p/'lib/libc++.a', *objects])
    out = b/'libpsl-target'
    run([profile/'meson', 'setup', *(['--reconfigure', '--clearcache']
         if (out/'meson-private/coredata.dat').exists() else []),
         out, b/'libpsl-0.21.5',
         '--cross-file', b/'glib-cross.ini', '--prefix', p,
         '-Druntime=libicu', '-Dtests=false', '-Ddocs=false',
         '--wrap-mode=nodownload'])
    run([profile/'ninja', '-C', out, '-j8', 'src/libpsl.a'])
    stage_meson(out)
elif which == 'libsoup':
    run([sys.executable, r/'ports/nyxt/wpe/apply-patches.py',
         b/'libsoup-3.6.5', 'libsoup-cancelled-preconnect.patch'])
    # These are upstream Python generators, run on the build host only.
    (p/'bin').mkdir(exist_ok=True)
    for name in ['glib-mkenums', 'glib-genmarshal']:
        shutil.copy2(b/'glib-gio-target/gobject'/name, p/'bin'/name)
    out = b/'libsoup-target'
    run([profile/'meson', 'setup', out, b/'libsoup-3.6.5',
         '--cross-file', b/'glib-cross.ini', '--prefix', p,
         '-Dgssapi=disabled', '-Dntlm=disabled', '-Dbrotli=disabled',
         '-Dintrospection=disabled', '-Dvapi=disabled', '-Ddocs=disabled',
         '-Dtests=false', '-Dsysprof=disabled', '-Dpkcs11_tests=disabled',
         '-Dtls_check=false', '--wrap-mode=nodownload'])
    # tls_check only controls a host configure probe; the target is linked
    # with real glib-networking and qualified against verified TLS below.
    run([profile/'ninja', '-C', out, '-j8', 'libsoup/libsoup-3.0.a'])
    stage_meson(out)
else:
    raise SystemExit('unknown library')
