#!/usr/bin/env python3
"""Cross-build WPE's rendering dependencies against the existing shared libsa.

Objects and source extractions live in RAM scratch; installed libraries and
source provenance remain in the repository. No target binary runs on the host.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

r = Path(__file__).resolve().parents[3]
b = r/'build/wpe-assessment'
p = b/'sysroot'
profile = Path((b/'build-tools.txt').read_text().splitlines()[0]).parent
pointer = b/'render-build-root.txt'
if not pointer.exists() or not Path(pointer.read_text().strip()).exists():
    pointer.write_text(tempfile.mkdtemp(prefix='darterfly-wpe-', dir='/dev/shm')+'\n')
w = Path(pointer.read_text().strip())
(w/'sources').mkdir(exist_ok=True)
env = dict(os.environ)
for k in ['CPATH', 'C_INCLUDE_PATH', 'CPLUS_INCLUDE_PATH', 'LIBRARY_PATH',
          'LD_LIBRARY_PATH', 'LD_PRELOAD']:
    env.pop(k, None)
env.update(PATH=str(p/'bin')+':'+str(profile)+':'+env['PATH'],
           CC=str(r/'ports/nyxt/wpe/target-cc.py'),
           CXX=str(r/'ports/nyxt/wpe/target-cxx.sh'),
           AR=str(profile/'llvm-ar'), RANLIB=str(profile/'llvm-ranlib'),
           PKG_CONFIG_LIBDIR=str(p/'lib/pkgconfig'), PKG_CONFIG_PATH='',
           CFLAGS='-O2 -ffunction-sections -fdata-sections',
           CXXFLAGS='-O2 -ffunction-sections -fdata-sections', LDFLAGS='-static')

def run(args, cwd=r):
    print('+', ' '.join(map(str, args)), flush=True)
    subprocess.run(list(map(str, args)), cwd=cwd, env=env, check=True)

def source(name):
    sources = []
    for f in ['render-sources.txt', 'render-extra-sources.txt']:
        sources += (r/'ports/nyxt/wpe'/('guix-'+f)).read_text().splitlines()
    matches = [Path(s) for s in sources if Path(s).name.split('-', 1)[1].startswith(name+'-')]
    if len(matches) != 1:
        raise RuntimeError(f'Ambiguous or absent Guix source: {name}: {matches}')
    src = matches[0]
    dest = w/'sources'/src.name.split('-', 1)[1]
    if not dest.exists():
        dest.mkdir()
        if src.is_dir():
            shutil.copytree(src, dest, dirs_exist_ok=True)
        else:
            run(['tar', 'xf', src, '-C', dest, '--strip-components=1'])
    # Store directory sources retain read-only modes when copied.
    for item in [dest, *dest.rglob("*")]:
        if not item.is_symlink():
            item.chmod(item.stat().st_mode | 0o200)
    return dest

def cmake(name, options, subdir=''):
    out = w/(name+'-target')
    run([profile/'cmake', '-S', source(name)/subdir, '-B', out, '-G', 'Ninja',
         '-DCMAKE_TOOLCHAIN_FILE='+str(b/'jsc-toolchain.cmake'),
         '-DCMAKE_POLICY_VERSION_MINIMUM=3.5',
         '-DCMAKE_INSTALL_PREFIX='+str(p), '-DCMAKE_INSTALL_LIBDIR=lib',
         '-DCMAKE_BUILD_TYPE=MinSizeRel', '-DBUILD_SHARED_LIBS=OFF',
         *['-D'+x for x in options]])
    run([profile/'cmake', '--build', out, '-j8'])
    run([profile/'cmake', '--install', out])

def meson(name, options, targets):
    out = w/(name+'-target')
    run([profile/'meson', 'setup', *(['--reconfigure']
         if (out/'meson-private/coredata.dat').exists() else []),
         out, source(name), '--cross-file', b/'glib-cross.ini',
         '--prefix', p, '--libdir=lib', '--wrap-mode=nodownload',
         *['-D'+x for x in options]])
    run([profile/'ninja', '-C', out, '-j8', *targets])
    installed = json.loads((out/'meson-info/intro-installed.json').read_text())
    for src, dest in installed.items():
        src, dest = Path(src), Path(dest)
        if dest.suffix not in ('.a', '.h', '.pc'):
            continue
        if not dest.is_relative_to(p):
            raise RuntimeError(f'Unexpected install destination: {dest}')
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(src, dest)

def autotools(name, options, subdirs):
    src = source(name)
    out = w/(name+'-target')
    out.mkdir(exist_ok=True)
    if name == 'libgpg-error':
        # Upstream can derive the lock ABI from a cross-compiled object.
        # Extend that existing path to our explicit generic ELF target.
        run([sys.executable, r/'ports/nyxt/wpe/apply-patches.py', src,
             'libgpg-error-cross-lock.patch'])
        env['OBJDUMP'] = str(profile/'llvm-objdump')
    if not (out/'Makefile').exists() or name == 'libgpg-error':
        run([src/'configure', '--host=x86_64-unknown-none',
             '--prefix='+str(p), '--disable-shared', '--enable-static',
             *options], cwd=out)
    for sub in subdirs:
        run(['make', '-j8', 'CFLAGS_FOR_BUILD=-O2 -isystem '+str(profile.parent/'include')], cwd=out/sub)
        run(['make', 'install'], cwd=out/sub)
    for pc in out.rglob('*.pc'):
        shutil.copyfile(pc, p/'lib/pkgconfig'/pc.name)

def stage_khronos_headers():
    # Architecture-neutral Khronos declarations, no host Mesa binary.
    origins = json.loads((r/'ports/nyxt/wpe/render-header-origins.json').read_text())
    for relative, origin in origins.items():
        dest = p/'include'/relative
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(origin, dest)

if __name__ == '__main__':
    for name in sys.argv[1:]:
        if name == 'libpng':
            cmake(name, ['PNG_SHARED=OFF', 'PNG_TESTS=OFF', 'PNG_TOOLS=OFF',
                         'PNG_EXECUTABLES=OFF'])
        elif name == 'libjpeg-turbo':
            cmake(name, ['ENABLE_SHARED=OFF', 'ENABLE_STATIC=ON', 'WITH_TURBOJPEG=OFF',
                         'WITH_SIMD=OFF', 'ENABLE_TESTING=OFF'])
        elif name == 'libwebp':
            cmake(name, ['WEBP_ENABLE_SIMD=OFF', 'WEBP_BUILD_ANIM_UTILS=OFF',
                         'WEBP_BUILD_CWEBP=OFF', 'WEBP_BUILD_DWEBP=OFF',
                         'WEBP_BUILD_GIF2WEBP=OFF', 'WEBP_BUILD_IMG2WEBP=OFF',
                         'WEBP_BUILD_VWEBP=OFF', 'WEBP_BUILD_WEBPINFO=OFF',
                         'WEBP_BUILD_WEBPMUX=OFF', 'WEBP_BUILD_EXTRAS=OFF'])
        elif name == 'libxml2':
            cmake(name, ['LIBXML2_WITH_PYTHON=OFF', 'LIBXML2_WITH_PROGRAMS=OFF',
                         'LIBXML2_WITH_TESTS=OFF', 'LIBXML2_WITH_LZMA=OFF',
                         'LIBXML2_WITH_ICONV=ON'])
        elif name == 'freetype':
            cmake(name, ['FT_DISABLE_HARFBUZZ=ON', 'FT_DISABLE_BZIP2=ON',
                         'FT_DISABLE_BROTLI=ON', 'FT_REQUIRE_ZLIB=ON',
                         'FT_REQUIRE_PNG=ON'])
        elif name == 'expat':
            cmake(name, ['EXPAT_BUILD_TOOLS=OFF', 'EXPAT_BUILD_EXAMPLES=OFF',
                         'EXPAT_BUILD_TESTS=OFF', 'EXPAT_SHARED_LIBS=OFF',
                         'EXPAT_BUILD_DOCS=OFF'])
        elif name == 'harfbuzz':
            meson(name, ['glib=disabled', 'gobject=disabled', 'cairo=disabled',
                         'icu=enabled', 'freetype=enabled', 'tests=disabled',
                         'docs=disabled', 'utilities=disabled', 'introspection=disabled'],
                  ['src/libharfbuzz.a', 'src/libharfbuzz-subset.a', 'src/libharfbuzz-icu.a'])
        elif name == 'fontconfig':
            run([sys.executable, r/'ports/nyxt/wpe/apply-patches.py', source(name),
                 'fontconfig-random-state-check.patch'])
            meson(name, ['doc=disabled', 'nls=disabled', 'tests=disabled',
                         'tools=disabled', 'cache-build=disabled', 'xml-backend=expat',
                         'default-fonts-dirs=/usr/share/fonts',
                         'baseconfig-dir=/etc/fonts', 'cache-dir=/var/cache/fontconfig'],
                  ['src/libfontconfig.a'])
        elif name == 'libepoxy':
            run([sys.executable, r/'ports/nyxt/wpe/apply-patches.py', source(name),
                 'epoxy-unused-err-header.patch'])
            stage_khronos_headers()
            meson(name, ['glx=no', 'egl=yes', 'x11=false', 'tests=false', 'docs=false'],
                  ['src/libepoxy.a'])
        elif name == 'libxkbcommon':
            meson(name, ['enable-x11=false', 'enable-wayland=false',
                         'enable-tools=false', 'enable-docs=false', 'enable-xkbregistry=false',
                         'enable-bash-completion=false'],
                  ['libxkbcommon.a'])
        elif name == 'libgpg-error':
            autotools(name, ['--disable-nls', '--disable-doc', '--disable-tests',
                             '--disable-languages'], ['src'])
        elif name == 'libgcrypt':
            autotools(name, ['--disable-doc', '--disable-asm', '--disable-jent-support',
                             '--disable-avx-support', '--disable-avx2-support',
                             '--disable-avx512-support', '--disable-padlock-support',
                             '--disable-aesni-support', '--disable-shaext-support',
                             '--disable-pclmul-support', '--disable-sse41-support',
                             '--disable-gfni-support', '--disable-drng-support',
                             '--with-libgpg-error-prefix='+str(p)],
                      ['compat', 'mpi', 'cipher', 'random', 'src'])
        elif name == 'libtasn1':
            autotools(name, ['--disable-doc', '--disable-tools'], ['lib'])
        else:
            raise SystemExit('Unknown rendering dependency: '+name)
