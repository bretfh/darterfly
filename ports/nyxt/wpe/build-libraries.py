#!/usr/bin/env python3
"""Build pinned C dependencies and GLib against the shared libsa headers."""
import os
from pathlib import Path
import subprocess
import sys
root=Path(__file__).resolve().parents[3]
b=root/'build/wpe-assessment'
prefix=b/'sysroot'
profile=Path((b/'build-tools.txt').read_text().splitlines()[0]).parent
cc=root/'ports/nyxt/wpe/target-cc.py'
env=dict(os.environ)
env['PATH']=str(profile)+':'+env['PATH']
for key in ['CPATH','C_INCLUDE_PATH','CPLUS_INCLUDE_PATH','LIBRARY_PATH']:
    env.pop(key,None)
env.update(CC=str(cc),CXX=str(cc.with_name('target-cxx.sh')),AR=str(profile/'llvm-ar'),RANLIB=str(profile/'llvm-ranlib'),
           PKG_CONFIG_LIBDIR=str(prefix/'lib/pkgconfig'),PKG_CONFIG_PATH='',
           CFLAGS='-O2 -ffunction-sections -fdata-sections')
def run(args,cwd=root):
    print('+',' '.join(map(str,args)),flush=True)
    subprocess.run(list(map(str,args)),cwd=cwd,env=env,check=True)
(prefix/'lib').mkdir(parents=True,exist_ok=True)
for name in ['c','m','pthread','dl','rt']:
    path=prefix/'lib'/('lib'+name+'.a')
    if not path.exists():run([profile/'llvm-ar','rcs',path])
# Empty conventional link-name archives refer to libsa exports, not a libc.
which=sys.argv[1] if len(sys.argv)>1 else 'pcre2'
if which=='pcre2':
    out=b/'pcre2-target'
    run([profile/'cmake','-S',b/'pcre2-10.42','-B',out,'-G','Ninja',
         '-DCMAKE_POLICY_VERSION_MINIMUM=3.5','-DCMAKE_SYSTEM_NAME=Generic','-DCMAKE_C_COMPILER='+str(cc),
         '-DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY',
         '-DCMAKE_INSTALL_PREFIX='+str(prefix),'-DBUILD_SHARED_LIBS=OFF',
         '-DPCRE2_BUILD_PCRE2GREP=OFF','-DPCRE2_BUILD_TESTS=OFF',
         '-DPCRE2_SUPPORT_JIT=OFF','-DCMAKE_BUILD_TYPE=MinSizeRel'])
    run([profile/'cmake','--build',out,'-j','8'])
    run([profile/'cmake','--install',out])
elif which in ['libffi','libiconv']:
    version={'libffi':'3.4.6','libiconv':'1.18'}[which]
    src=b/(which+'-'+version);out=b/(which+'-target');out.mkdir(exist_ok=True)
    if not (out/'Makefile').exists():
        run([src/'configure','--host=x86_64-unknown-none',
             '--prefix='+str(prefix),'--disable-shared','--enable-static',
             '--disable-docs','--disable-multi-os-directory'],cwd=out)
    if which=='libiconv':
        # Only the encoding libraries; the iconv CLI pulls in gnulib utilities.
        import shutil
        for sub in ['libcharset','lib']:
            run(['make','-j8'],cwd=out/sub)
            run(['make','install'],cwd=out/sub)
        shutil.copyfile(out/'include/iconv.h.inst',prefix/'include/iconv.h')
    else:
        run(['make','-j8'],cwd=out);run(['make','install'],cwd=out)
elif which=='zlib':
    import shutil
    src=b/'zlib-1.3.1'; out=b/'zlib-target';out.mkdir(exist_ok=True)
    if not (out/'Makefile').exists():
        run([src/'configure','--static','--prefix='+str(prefix)],cwd=out)
    run(['make','-j8','libz.a'],cwd=out)
    shutil.copyfile(out/'libz.a',prefix/'lib/libz.a')
    for header in ['zlib.h','zconf.h']:
        source=out/header if (out/header).exists() else src/header
        shutil.copyfile(source,prefix/'include'/header)
    shutil.copyfile(out/'zlib.pc',prefix/'lib/pkgconfig/zlib.pc')
elif which=='icu':
    src=b/'icu/source';out=b/'icu-target';out.mkdir(exist_ok=True)
    import shutil
    env['CXXFLAGS']='-O2 -ffunction-sections -fdata-sections -DU_HAVE_NL_LANGINFO_CODESET=0'
    env['icu_cv_host_frag']='mh-darterfly'
    shutil.copyfile(root/'ports/nyxt/wpe/icu-mh-darterfly',src/'config/mh-darterfly')
    if not (out/'Makefile').exists() or 'U_HAVE_NL_LANGINFO_CODESET=0' not in (out/'icudefs.mk').read_text():
        run([src/'configure','--host=x86_64-unknown-none',
             '--prefix='+str(prefix),'--with-cross-build='+str(b/'icu-host'),
             '--disable-shared','--enable-static','--disable-tests',
             '--disable-samples','--disable-extras','--disable-tools',
             '--with-data-packaging=static'],cwd=out)
    run(['make','-j12'],cwd=out);run(['make','install'],cwd=out)
elif which in ['glib','gio']:
    run([sys.executable, root/'ports/nyxt/wpe/apply-patches.py',
         b/'glib-2.86.0','glib-core-qualification.patch',
         'glib-libsa-locale.patch','glib-darterfly-volumes.patch','glib-spawn-cloexec-default.patch'])
    cross=b/'glib-cross.ini'
    cross.write_text(f'''[binaries]
c = '{cc}'
cpp = '{cc.with_name('target-cxx.sh')}'
ar = '{profile/'llvm-ar'}'
strip = '{profile/'llvm-strip'}'
pkg-config = '{profile/'pkg-config'}'
[host_machine]
system = 'darterfly'
cpu_family = 'x86_64'
cpu = 'x86_64'
endian = 'little'
[properties]
needs_exe_wrapper = true
[built-in options]
c_args = ['-O2', '-ffunction-sections', '-fdata-sections']
default_library = 'static'
b_staticpic = false
''')
    out=b/('glib-target' if which=='glib' else 'glib-gio-target')
    run([profile/'meson','setup',out,b/'glib-2.86.0','--cross-file',cross,
         '--prefix',prefix,'-Dtests=false','-Dinstalled_tests=false',
         '-Dintrospection=disabled','-Dnls=disabled','-Ddocumentation=false',
         '-Dman-pages=disabled','-Dlibmount=disabled','-Dselinux=disabled',
         '-Dxattr=false','-Dlibelf=disabled','-Dsysprof=disabled',
         '-Dforce_posix_threads=true','-Ddarterfly_core_only='+('true' if which=='glib' else 'false'),
         '--wrap-mode=nodownload'])
    run([profile/'ninja','-C',out,'-j8','glib/libglib-2.0.a',
         'gobject/libgobject-2.0.a','gmodule/libgmodule-2.0.a',
         'subprojects/proxy-libintl/libintl.a',
         *(['gio/libgio-2.0.a'] if which=='gio' else [])])
else:
    raise SystemExit('unknown library')
