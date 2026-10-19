#!/usr/bin/env python3
"""Cross seed upstream Nyxt build inputs against Darterfly's shared libsa."""
import os
import shutil
from pathlib import Path
import subprocess
import sys
r = Path(__file__).resolve().parents[3]
b = r / 'build/wpe-assessment'
tools = Path((b / 'build-tools.txt').read_text().splitlines()[0]).parent
w = Path((b / 'render-build-root.txt').read_text().strip()) / 'nyxt-native'
w.mkdir(exist_ok=True)
env = dict(os.environ, PATH=str(tools) + ':' + os.environ['PATH'])
for name in ['CPATH', 'C_INCLUDE_PATH', 'CPLUS_INCLUDE_PATH', 'LIBRARY_PATH']:
    env.pop(name, None)
def run(args, cwd=r):
    print('+', ' '.join(map(str, args)), flush=True)
    subprocess.run(list(map(str, args)), cwd=cwd, env=env, check=True)
if sys.argv[1] == 'pkgconf':
    source = (b / 'pkgconf-source').resolve(strict=True)
    src, out = b / 'pkgconf-2.5.1', b / 'pkgconf-target'
    if not src.exists():
        run(['tar', '-xf', source, '-C', b])
    # Refresh cached tool paths after the Guix host profile changes.
    run([tools / 'meson', 'setup',
         *(['--reconfigure'] if (out / 'build.ninja').exists() else []),
         out, src, '--cross-file', b / 'glib-cross.ini',
         '--prefix', '/usr', '--libdir', 'lib', '-Dtests=disabled'])
    run([tools / 'ninja', '-C', out, '-j8', 'libpkgconf.a',
         'pkgconf.p/cli_main.c.o', 'pkgconf.p/cli_getopt_long.c.o',
         'pkgconf.p/cli_renderer-msvc.c.o'])
    run([tools / 'ld.lld', '-r', '--gc-sections', '--entry=main',
         *sorted((out / 'pkgconf.p').glob('*.o')), out / 'libpkgconf.a',
         '-o', w / 'pkgconf.o'])
elif sys.argv[1] == 'fixposix':
    src = (b / 'fixposix-source').resolve(strict=True)
    out = w / 'fixposix'
    include = w / 'root/usr/include'
    out.mkdir(exist_ok=True)
    for tree in [include, *include.rglob('*')]:
        if tree.exists(): tree.chmod(0o755 if tree.is_dir() else 0o644)
    shutil.copytree(src / 'src/include', include, dirs_exist_ok=True)
    for tree in [include, *include.rglob('*')]:
        tree.chmod(0o755 if tree.is_dir() else 0o644)
    time_h = (include / 'lfp/time.h.in').read_text()
    for key in ['HAVE_CLOCKID_T', 'HAVE_CLOCK_GETTIME']:
        time_h = time_h.replace('@' + key + '@', '1')
    (include / 'lfp/time.h').write_text(time_h)
    (out / 'config.h').write_text('\n'.join('#define ' + name + ' 1' for name in
        ['HAVE_STRNLEN', 'HAVE_STRNDUP',
         'HAVE_CLOCK_GETTIME', 'HAVE_CLOCKID_T']) + '\n')
    buildinfo = (src / 'src/lib/buildinfo.c.in').read_text()
    for key, value in {'LFP_MAJOR_VERSION':'0', 'LFP_MINOR_VERSION':'4',
                       'LFP_MICRO_VERSION':'3', 'LFP_VCSID':'guix-0.4.3-darterfly'}.items():
        buildinfo = buildinfo.replace('@' + key + '@', value)
    (out / 'buildinfo.c').write_text(buildinfo)
    sources = sorted((src / 'src/lib').glob('*.c')) + [out / 'buildinfo.c']
    failures = []
    for source in sources:
        if source.name == 'install_signalfd.c':
            continue # Not part of upstream's active library source list.
        if source.name == 'spawn.c':
            source = r / 'ports/nyxt/wpe/fixposix-spawn.c'
        elif source.name == 'spawn_file_actions.c':
            adapted = out / source.name
            adapted.write_text(source.read_text() + '\n' +
                (r / 'ports/nyxt/wpe/fixposix-file-actions.inc').read_text())
            source = adapted
        elif source.name == 'stdlib.c':
            adapted = out / source.name
            text = source.read_text()
            assert text.count('    }\n#endif\n}') == 1, 'Unexpected lfp_ptsname source'
            text = text.replace('    }\n#endif\n}',
                '    }\n#else\n    SYSERR(ENOSYS);\n#endif\n}')
            adapted.write_text(text)
            source = adapted
        elif source.name == 'socket.c':
            # Upstream omits a return when no peer-credential API is available.
            adapted = out / source.name
            text = source.read_text()
            assert text.count('    return 0;\n#endif\n}') == 1, 'Unexpected peer credentials source'
            text = text.replace('    return 0;\n#endif\n}',
                                '    return 0;\n#else\n    SYSERR(ENOTSUP);\n#endif\n}')
            adapted.write_text(text)
            source = adapted
        args = [r / 'ports/nyxt/wpe/target-cc.py' , '-c', '-O2', '-fPIC',
                '-ftls-model=global-dynamic', '-fvisibility=hidden',
                '-include', out / 'config.h', '-include', src / 'src/lib/aux/macros.h',
                '-I' + str(include), '-iquote', str(src / 'src/lib'),
                source, '-o', out / (source.stem + '.o')]
        result = subprocess.run(list(map(str,args)), env=env)
        if result.returncode: failures.append(source.name)
    if failures:
        raise SystemExit('Failed sources: ' + ', '.join(failures))
    (out / 'spawn.o').unlink(missing_ok=True)
    run([tools / 'ld.lld', '-shared', '-z', 'now', '-z', 'relro',
         '--hash-style=both', '-soname', 'libfixposix.so',
         *sorted(out.glob('*.o')), '-o', out / 'libfixposix.so'])
    lib = w / 'root/usr/lib'
    (lib / 'pkgconfig').mkdir(parents=True, exist_ok=True)
    shutil.copyfile(out / 'libfixposix.so', lib / 'libfixposix.so')
    (lib / 'pkgconfig/libfixposix.pc').write_text("""prefix=/usr
libdir=${prefix}/lib
includedir=${prefix}/include
Name: LibFixPOSIX
Description: Upstream POSIX wrappers using Darterfly shared libsa
Version: 0.4.3
Libs: -L${libdir} -lfixposix
Cflags: -I${includedir}
""")
elif sys.argv[1] == 'sqlite':
    out = w / 'sqlite.o'
    lib = w / 'root/usr/lib/libsqlite3.so'
    lib.parent.mkdir(parents=True, exist_ok=True)
    run([r / 'ports/nyxt/wpe/target-cc.py', '-c', '-O2', '-fPIC',
         '-ftls-model=global-dynamic', '-DSQLITE_THREADSAFE=1',
         '-DSQLITE_OMIT_LOAD_EXTENSION', b / 'sqlite-autoconf-3530100/sqlite3.c',
         '-o', out])
    run([tools / 'ld.lld', '-shared', '-z', 'now', '-z', 'relro',
         '--hash-style=both', '-soname', 'libsqlite3.so', out, '-o', lib])
else:
    raise SystemExit('Unknown component: ' + sys.argv[1])
