#!/usr/bin/env python3
"""Link upstream WPE process entry points for the native CRT guest harness.

Run build-webkit.py WebKit first. Keep all large intermediate objects in the
recorded RAM scratch, and never execute a target binary on the build host.
"""
from pathlib import Path
import importlib.util
import re
import shlex
import sys
spec=importlib.util.spec_from_file_location('render',Path(__file__).with_name('build-render-libraries.py'))
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
r,b,p,w,profile,run=m.r,m.b,m.p,m.w,m.profile,m.run
out=w/'webkit-target';src=b/'wpewebkit-2.54.1/Source'
work=w/'engine';work.mkdir(exist_ok=True)
lines=(out/'build.ninja').read_text().splitlines()

def compile_flags(suffix):
    start=next(i for i,line in enumerate(lines)
               if line.startswith('build ') and suffix+':' in line)
    flags=[]
    for line in lines[start+1:]:
        if not line: break
        if line.startswith(('  DEFINES = ','  INCLUDES = ')):
            flags+=shlex.split(line.split(' = ',1)[1])
    return flags

def compile_cxx(source,object,edge,extra=()):
    run([r/'ports/nyxt/wpe/target-cxx.sh','-c','-Os','-std=c++23',
         '-fno-rtti','-fno-exceptions','-DNDEBUG','-ffunction-sections',
         '-fdata-sections','-include',src/'WebKit/config.h',
         *compile_flags(edge),*extra,source,'-o',object])

compile_cxx(r/('ports/nyxt/wpe/nyxt-engine.cpp' if '--nyxt' in sys.argv else 'ports/nyxt/wpe/engine-probe.cpp'),work/('nyxt-engine.o' if '--nyxt' in sys.argv else 'engine-probe.o'),
            'WebKitUIProcess.dir/UIProcess/API/glib/WebKitWebView.cpp.o')
for name,edge,extra in [
    ('WPEWebProcess','WebProcess.dir/WebProcess/EntryPoint/unix/WebProcessMain.cpp.o',()),
    ('WPENetworkProcess','NetworkProcess.dir/NetworkProcess/EntryPoint/unix/NetworkProcessMain.cpp.o',('-DDARTER_NETWORK_PROCESS',))]:
    compile_cxx(r/'ports/nyxt/wpe/engine-entry.cpp',work/(name+'.o'),edge,extra)
# Recompile the platform bundle adapter explicitly alongside the harness.
# This also avoids relying on a cached object from before the static patch.
bundle_edge='WebKitWebProcess.dir/WebProcess/InjectedBundle/glib/InjectedBundleGlib.cpp.o'
compile_cxx(src/'WebKit/WebProcess/InjectedBundle/glib/InjectedBundleGlib.cpp',
            work/'InjectedBundleGlib.o',bundle_edge)
run([r/'ports/nyxt/wpe/target-cc.py','-c','-Os','-ffunction-sections',
     '-fdata-sections','-I'+str(p/'include/glib-2.0'),
     '-I'+str(p/'lib/glib-2.0/include'),r/'ports/nyxt/wpe/static-openssl.c',
     '-o',work/'static-openssl.o'])
media = 'USE_GSTREAMER:BOOL=ON' in (out/'CMakeCache.txt').read_text()
if media:
    run([r/'ports/nyxt/wpe/target-cc.py', '-c', '-Os', '-ffunction-sections',
         '-fdata-sections', '-DGST_STATIC_COMPILATION',
         '-I'+str(p/'include/gstreamer-1.0'), '-I'+str(p/'include/glib-2.0'),
         '-I'+str(p/'lib/glib-2.0/include'), r/'ports/nyxt/wpe/static-media.c',
         '-o', work/'static-media.o'])
if '--compile-only' in sys.argv:
    raise SystemExit(0)

# Upstream STATIC targets expose some OBJECT sublibraries only through their
# link interface. Gather every current object edge, not old files on disk.
targets={'LowLevelInterpreterLib','WTF','bmalloc','JavaScriptCore','JavaScriptCore_c','WebCore','WebCore_c',
         'WebKit','WebKitUIProcess','WebKitWebProcess','WebKitNetworkProcess',
         'WebKitShared','WebKitGPUProcess','WPEPlatform','WPEPlatformHeadless'}
objects=[]
for line in lines:
    if not line.startswith('build '):continue
    edge=line.split(': ',1)[0][6:]
    match=re.search(r'/CMakeFiles/([^/]+)\.dir/',edge)
    if edge.endswith('.o') and match and (match[1] in targets or
       match[1].startswith(('WebCore','JavaScriptCore','WebKit'))):
        if not edge.endswith(bundle_edge):objects.append(out/edge)
missing=[str(path) for path in objects if not path.is_file()]
if missing:
    raise SystemExit(f'{len(missing)} engine objects are not built; run build-webkit.py WebKit. First: {missing[0]}')
objects += [work/'InjectedBundleGlib.o']
response=work/'engine-objects.rsp'
response.write_text('\n'.join('"'+str(path)+'"' for path in objects)+'\n')
archive=work/'libengine-objects.a'
if archive.exists():archive.unlink()
run([profile/'llvm-ar','rcs',archive,'@'+str(response)])
libs=['epoxy','xkbcommon','fontconfig','freetype','harfbuzz','png16','jpeg',
      'webp','webpmux','webpdemux','sharpyuv','harfbuzz-icu','xml2','expat','gcrypt','gpg-error','tasn1',
      'soup-3.0','nghttp2','sqlite3','psl','ssl','crypto','gio-2.0','gthread-2.0',
      'gmodule-2.0','gobject-2.0','glib-2.0','icuuc','icui18n','icudata',
      'pcre2-8','ffi','iconv','z']
archives=[archive,out/'lib/libSkia.a',out/'lib/libPAL.a',out/'lib/libxdgmime.a',
          *[p/'lib'/('lib'+name+'.a') for name in libs],
          b/'glib-networking-target/tls/openssl/libgioopenssl.a',
          b/'glib-gio-target/subprojects/proxy-libintl/libintl.a']
if media:
    archives += sorted((p/'lib/gstreamer-1.0').glob('*.a'))
    archives += sorted((p/'lib').glob('libgst*.a'))
    archives += [p/'lib'/('lib'+name+'.a') for name in
                 ['avcodec', 'avformat', 'avfilter', 'avutil', 'swresample', 'swscale',
                  'vpx', 'opus', 'vorbis', 'vorbisenc', 'ogg']]
for name in (['nyxt-engine'] if '--nyxt' in sys.argv else ['engine-probe','WPEWebProcess','WPENetworkProcess']):
    run([profile/'ld.lld','-r','--gc-sections','--entry=main',work/(name+'.o'),
         work/'static-openssl.o', *([work/'static-media.o'] if media else []), '--start-group',*archives,'--end-group',
         '-o',work/(name+'-guest.o')])
print('Engine partial links:',work)
