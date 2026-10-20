#!/usr/bin/env python3
"""Cross-build pinned GStreamer and codecs against Darterfly's shared libsa."""
import importlib.util
import json
from pathlib import Path
import shutil
import sys
spec = importlib.util.spec_from_file_location('render', Path(__file__).with_name('build-render-libraries.py'))
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
r, b, p, w, profile, run = m.r, m.b, m.p, m.w, m.profile, m.run


def source(name):
    paths = [Path(x) for x in (r/'ports/nyxt/wpe/guix-media-sources.txt').read_text().splitlines()]
    path, = [x for x in paths if x.name.split('-', 1)[1].startswith(name+'-')]
    dest = w/'sources'/path.name.split('-', 1)[1]
    if not dest.exists():
        if path.is_dir():
            shutil.copytree(path, dest)
        else:
            dest.mkdir(parents=True)
            run(['tar', 'xf', path, '-C', dest, '--strip-components=1'])
        for item in [dest, *dest.rglob('*')]:
            if not item.is_symlink():
                item.chmod(item.stat().st_mode | 0o200)
    return dest


def meson(name, options):
    out = w/(name+'-target')
    run([profile/'meson', 'setup', *(['--reconfigure'] if (out/'build.ninja').exists() else []),
         out, source(name), '--cross-file', b/'glib-cross.ini', '--prefix', p,
         '--libdir=lib', '--wrap-mode=nodownload', '-Dauto_features=disabled',
         '-Ddefault_library=static', '-Dbuildtype=release', *['-D'+x for x in options]])
    run([profile/'ninja', '-C', out, '-j8'])
    for src, dest in json.loads((out/'meson-info/intro-installed.json').read_text()).items():
        src, dest = Path(src), Path(dest)
        if dest.suffix not in ('.a', '.h', '.pc') or not src.is_file():
            continue
        if not dest.is_relative_to(p):
            raise RuntimeError('Unexpected install destination: '+str(dest))
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(src, dest)


def cmake(name, options):
    original = m.source
    m.source = source
    try:
        m.cmake(name, options + [
            "CMAKE_AR="+str(profile/"llvm-ar"),
            "CMAKE_RANLIB="+str(profile/"llvm-ranlib")])
    finally:
        m.source = original


if __name__ == '__main__':
    for name in sys.argv[1:] or ['gstreamer']:
        if name == 'gstreamer':
            meson(name, ['gst_parse=true', 'registry=true', 'tracer_hooks=false'])
        elif name == 'libogg':
            cmake(name, ['BUILD_TESTING=OFF', 'INSTALL_DOCS=OFF'])
        elif name == 'libvorbis':
            cmake(name, ['BUILD_TESTING=OFF',
                         'CMAKE_C_FLAGS=-O2 -ffunction-sections -fdata-sections -DHAVE_ALLOCA_H=1'])
        elif name == 'opus':
            cmake(name, ['OPUS_BUILD_TESTING=OFF', 'OPUS_BUILD_PROGRAMS=OFF',
                         'OPUS_INSTALL_PKG_CONFIG_MODULE=ON', 'OPUS_STACK_PROTECTOR=OFF'])
        elif name == 'libvpx':
            out = w/(name+'-target')
            out.mkdir(exist_ok=True)
            run([source(name)/'configure', '--target=generic-gnu',
                 '--prefix='+str(p), '--disable-examples', '--disable-tools',
                 '--disable-docs', '--disable-unit-tests', '--disable-shared',
                 '--enable-static', '--disable-vp8-encoder', '--disable-vp9-encoder'], cwd=out)
            run(['make', '-j8'], cwd=out)
            run(['make', 'install'], cwd=out)
        elif name == 'ffmpeg':
            run([sys.executable, r/'ports/nyxt/wpe/apply-patches.py', source(name),
                 'ffmpeg-thread-name.patch'])
            # Decode only. Container handling, HTTP and TLS stay in the existing
            # GStreamer/WebKit stack; FFmpeg uses the same libsa and pthreads.
            out = w/(name+'-target')
            out.mkdir(exist_ok=True)
            run([source(name)/'configure', '--enable-cross-compile',
                 '--target-os=none', '--arch=x86_64',
                 '--cc='+str(r/'ports/nyxt/wpe/target-cc.py'),
                 '--ar='+str(profile/'llvm-ar'),
                 '--ranlib='+str(profile/'llvm-ranlib'),
                 '--prefix='+str(p), '--disable-autodetect',
                 '--disable-everything', '--disable-programs', '--disable-doc',
                 '--disable-network', '--disable-shared', '--enable-static',
                 '--disable-x86asm', '--disable-inline-asm',
                 '--enable-pthreads', '--enable-decoder=h264,aac,aac_latm',
                 '--enable-parser=h264,aac,aac_latm',
                 '--extra-cflags=-O2 -ffunction-sections -fdata-sections'], cwd=out)
            run(['make', '-j8'], cwd=out)
            run(['make', 'install'], cwd=out)
        elif name == 'gst-libav':
            meson(name, [])
        elif name == 'gst-plugins-base':
            meson(name, [x+'=enabled' for x in
                ['app', 'audioconvert', 'audioresample', 'audiotestsrc', 'playback',
                 'rawparse', 'subparse', 'typefind', 'videoconvertscale',
                 'videotestsrc', 'volume', 'ogg', 'opus', 'vorbis']])
        elif name == 'gst-plugins-bad':
            meson(name, ['videoparsers=enabled', 'opus=enabled', 'subenc=enabled'])
        elif name == 'gst-plugins-good':
            meson(name, [x+'=enabled' for x in
                ['autodetect', 'matroska', 'isomp4', 'vpx', 'wavparse',
                 'audioparsers', 'interleave', 'audiofx']])
        else:
            raise SystemExit('Unknown media library: '+name)
