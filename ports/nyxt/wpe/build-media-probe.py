#!/usr/bin/env python3
"""Build the native decoder/PCM qualification independently of WebKit."""
import importlib.util
from pathlib import Path
spec = importlib.util.spec_from_file_location('media', Path(__file__).with_name('build-media.py'))
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
r,b,p,w,profile,run = m.r,m.b,m.p,m.w,m.profile,m.run
for name in ['static-media', 'media-probe']:
    run([r/'ports/nyxt/wpe/target-cc.py', '-c', '-O2', '-ffunction-sections',
         '-fdata-sections', '-DGST_STATIC_COMPILATION',
         '-I'+str(p/'include/gstreamer-1.0'), '-I'+str(p/'include/glib-2.0'),
         '-I'+str(p/'lib/glib-2.0/include'), r/'ports/nyxt/wpe'/(name+'.c'),
         '-o', b/(name+'.o')])
archives = [*sorted((p/'lib/gstreamer-1.0').glob('*.a')),
            *sorted((p/'lib').glob('libgst*.a')),
            *[p/'lib'/('lib'+name+'.a') for name in
              ['avcodec','avformat','avfilter','avutil','swresample','swscale',
               'vpx','opus','vorbis','vorbisenc','ogg','gio-2.0', 'gmodule-2.0',
               'gobject-2.0','glib-2.0','pcre2-8','ffi','iconv','z']],
            b/'glib-gio-target/subprojects/proxy-libintl/libintl.a']
run([profile/'ld.lld','-r','--gc-sections','--entry=main', b/'media-probe.o',
     b/'static-media.o','--start-group',*archives,'--end-group',
     '-o', b/'media-guest.o'])
