#!/usr/bin/env python3
from pathlib import Path
import importlib.util
import shlex
spec=importlib.util.spec_from_file_location('render',Path(__file__).with_name('build-render-libraries.py'))
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
r,b,p,w,profile,run=m.r,m.b,m.p,m.w,m.profile,m.run
out=w/'webkit-target'; src=b/'wpewebkit-2.54.1/Source'
# Match Skia's public ABI, especially sk_sp's trivial_abi return convention.
ninja=(out/'build.ninja').read_text().splitlines()
edge=next(i for i,line in enumerate(ninja)
          if line.startswith('build ') and 'SkiaPaintingEngine.cpp.o:' in line)
public_defines=shlex.split(next(line.split(' = ',1)[1]
    for line in ninja[edge+1:edge+8] if line.startswith('  DEFINES = ')))
skia_defines=[flag for flag in public_defines if flag.startswith('-DSK_')]
includes=[out,src/'WTF',out/'Skia/Headers/top',src/'ThirdParty/skia',out/'WTF/DerivedSources',out/'bmalloc/Headers',
          src/'WebKit/WPEPlatform',out/'DerivedSources/WPEPlatform',
          p/'include/glib-2.0',p/'lib/glib-2.0/include']
run([r/'ports/nyxt/wpe/target-cxx.sh','-c','-O2','-std=c++23','-fno-rtti',
     '-fno-exceptions','-ffunction-sections','-fdata-sections',
     *skia_defines,'-include',src/'WTF/config.h','-DBUILDING_WPE__=1','-DHAVE_CONFIG_H=1','-DBUILDING_WITH_CMAKE=1',
     *['-I'+str(i) for i in includes],r/'ports/nyxt/wpe/platform-probe.cpp',
     '-o',b/'platform-probe.o'])
# Match only object edges that are still in the current generated build graph.
ninja=(out/'build.ninja').read_text().splitlines()
archives=[]
for name in ['WTF','bmalloc','WPEPlatform','WPEPlatformHeadless']:
    objects=[out/line.split(': ',1)[0][6:] for line in ninja
             if line.startswith('build ') and '/CMakeFiles/'+name+'.dir/' in line.split(': ',1)[0]
             and line.split(': ',1)[0].endswith('.o')]
    assert objects, name
    archive=w/('libprobe-'+name+'.a')
    if archive.exists(): archive.unlink()
    run([profile/'llvm-ar','rcs',archive,*objects])
    archives.append(archive)
libs=['epoxy','xkbcommon','gio-2.0','gmodule-2.0','gobject-2.0','glib-2.0',
      'icuuc','icui18n','icudata','pcre2-8','ffi','iconv','z',
      'fontconfig','freetype','harfbuzz','png16','jpeg','webp','webpdemux','sharpyuv','expat']
run([profile/'ld.lld','-r','--gc-sections','--entry=main',b/'platform-probe.o',
     '--start-group',out/'lib/libSkia.a',*archives,*[p/'lib'/('lib'+n+'.a') for n in libs],
     b/'glib-gio-target/subprojects/proxy-libintl/libintl.a',
     r/'build/cxx/compiler-builtins/libclang_rt.builtins.a','--end-group',
     '-o',b/'platform-guest.o'])
