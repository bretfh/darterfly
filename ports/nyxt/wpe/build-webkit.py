#!/usr/bin/env python3
"""Configure/build pinned upstream WPE for Darterfly, initially CPU rendering."""
import importlib.util
from pathlib import Path
import sys
import os
import re
spec = importlib.util.spec_from_file_location('render', Path(__file__).with_name('build-render-libraries.py'))
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
r, b, p, w, profile, run = m.r, m.b, m.p, m.w, m.profile, m.run
m.env['PATH'] = '/gnu/store/p1dhlkm7a36fq27a02576zmh1gvpvkdk-glib-2.86.0-bin/bin:'+m.env['PATH']
# WPE's GLib finder needs the real legacy thread archive as well as GLib.
run([profile/'ninja', '-C', b/'glib-gio-target', 'gthread/libgthread-2.0.a'])
import shutil
shutil.copyfile(b/'glib-gio-target/gthread/libgthread-2.0.a',
                p/'lib/libgthread-2.0.a')
unifdef_origin = r/'ports/nyxt/wpe/guix-unifdef-source.txt'
unifdef = Path(unifdef_origin.read_text().strip())/'bin/unifdef'
if not unifdef.is_file():
    raise SystemExit('Realize the pinned host unifdef package: '+str(unifdef.parent.parent))
src = b/'wpewebkit-2.54.1'
out = w/'webkit-target'
jobs = '-j'+str(int(os.environ.get('DARTER_WPE_JOBS', '16')))
host_tools = {name: shutil.which(name, path=m.env['PATH'])
              for name in ['perl', 'ruby', 'bison', 'gperf']}
missing = [name for name, path in host_tools.items() if not path]
if missing:
    raise SystemExit('Missing host build tools: '+', '.join(missing)+
                     '. Add them to the Guix build environment.')
run([sys.executable, r/'ports/nyxt/wpe/apply-patches.py', src,
     'jsc-darterfly-platform.patch', 'jsc-standalone-includes.patch',
     'skia-darterfly-baseline.patch', 'skia-darterfly-platform.patch',
     'wpe-darterfly-services.patch', 'wpe-darterfly-static-engine.patch', 'wpe-optional-gstreamer.patch', 'wpe-darterfly-cpu-renderer.patch', 'wpe-optional-drm-snapshot.patch', 'xdgmime-private-prefix.patch', 'wpe-static-injected-bundle.patch', 'wpe-darterfly-process-failure.patch', 'wpe-darterfly-sqlite-exclusive.patch', 'wpe-gstreamer-software.patch', 'wpe-software-video-metadata.patch'])
# Use the existing C-loop interpreter and native POSIX process launcher.
# The upstream headless platform exercises software buffers; a Darterfly
# display implementation will consume those buffers through WPEPlatform.
on = ['ENABLE_WPE_PLATFORM', 'ENABLE_WPE_PLATFORM_HEADLESS', 'ENABLE_C_LOOP',
      'USE_SYSTEM_MALLOC', 'USE_SYSTEM_UNIFDEF', 'ENABLE_VIDEO',
      'ENABLE_WEB_AUDIO', 'ENABLE_MEDIA_SOURCE', 'USE_GSTREAMER']
off = ['ENABLE_WPE_PLATFORM_DRM', 'ENABLE_WPE_PLATFORM_WAYLAND',
       'ENABLE_WPE_LEGACY_API', 'ENABLE_WPE_QT_API', 'USE_GBM', 'USE_LIBDRM',
       'USE_ATK', 'ENABLE_GAMEPAD', 'USE_GSTREAMER_GL', 'USE_GSTREAMER_WEBRTC',
       'ENABLE_MEDIA_STREAM', 'ENABLE_MEDIA_RECORDER', 'ENABLE_MEDIA_SESSION',
       'ENABLE_WEB_CODECS', 'ENABLE_WEBGL', 'ENABLE_GPU_PROCESS', 'USE_AVIF',
       'USE_JPEGXL', 'USE_LCMS', 'USE_WOFF2', 'USE_LIBHYPHEN', 'USE_FLITE',
       'ENABLE_SPEECH_SYNTHESIS', 'ENABLE_SPELLCHECK', 'ENABLE_XSLT',
       'ENABLE_WEBDRIVER', 'ENABLE_PDFJS', 'ENABLE_DOCUMENTATION',
       'ENABLE_INTROSPECTION', 'ENABLE_JOURNALD_LOG', 'USE_LIBBACKTRACE',
       'USE_SYSPROF_CAPTURE', 'DEVELOPER_MODE', 'ENABLE_API_TESTS',
       'ENABLE_LAYOUT_TESTS', 'ENABLE_MINIBROWSER', 'ENABLE_JIT',
       'ENABLE_DFG_JIT', 'ENABLE_FTL_JIT', 'ENABLE_WEBASSEMBLY',
       'ENABLE_REMOTE_INSPECTOR', 'ENABLE_SAMPLING_PROFILER',
       'ENABLE_UNIFIED_BUILDS', 'USE_HEADER_MAPS']
run([profile/'cmake', '-S', src, '-B', out, '-G', 'Ninja',
     '-DCMAKE_TOOLCHAIN_FILE='+str(b/'jsc-toolchain.cmake'),
     '-DPERL_EXECUTABLE='+host_tools['perl'],
     '-DPYTHON_EXECUTABLE='+sys.executable,
     '-DPython_EXECUTABLE='+sys.executable,
     '-DRuby_EXECUTABLE='+host_tools['ruby'],
     '-DBISON_EXECUTABLE='+host_tools['bison'],
     '-DGPERF_EXECUTABLE='+host_tools['gperf'],
     '-DGLIB_COMPILE_RESOURCES_EXECUTABLE=/gnu/store/p1dhlkm7a36fq27a02576zmh1gvpvkdk-glib-2.86.0-bin/bin/glib-compile-resources',
     '-DUNIFDEF_EXECUTABLE='+str(unifdef),
     '-DCMAKE_INSTALL_PREFIX=/usr', '-DCMAKE_INSTALL_LIBDIR=lib',
     '-DCMAKE_BUILD_TYPE=MinSizeRel', '-DPORT=WPE',
     '-DCMAKE_C_FLAGS=-ffunction-sections -fdata-sections',
     '-DCMAKE_CXX_FLAGS=-ffunction-sections -fdata-sections',
     *['-D'+k+'=ON' for k in on], *['-D'+k+'=OFF' for k in off]])
if '--configure-only' not in sys.argv:
    targets = sys.argv[1:] or ['WPEPlatform', 'WebCore']
    if 'WebKit' in targets:
        targets += ['LowLevelInterpreterLib']
        # Static WebKit exposes these OBJECT libraries through its interface;
        # archiving WebKit alone does not compile them.
        run([profile/'ninja', '-C', out, jobs, '-k8', 'DerivedSources/WebKit/MessageNames.h'])
        object_targets=set(re.findall(r'/CMakeFiles/([^/]+)\.dir/',
                                       (out/'build.ninja').read_text()))
        targets += sorted(name for name in object_targets
                          if name.startswith(('WebKit','WebCore','JavaScriptCore'))
                          and name not in targets)
    run([profile/'ninja', '-C', out, jobs, '-k8', *targets])
