#!/usr/bin/env python3
"""Build upstream JSC's interpreter against the Darterfly shared runtime."""
import os
from pathlib import Path
import subprocess
import sys
r=Path(__file__).resolve().parents[3]
b=r/'build/wpe-assessment'
profile=Path((b/'build-tools.txt').read_text().splitlines()[0]).parent
env=dict(os.environ)
env['PATH']=str(profile)+':'+env['PATH']
for k in ['CPATH','C_INCLUDE_PATH','CPLUS_INCLUDE_PATH','LIBRARY_PATH']:
    env.pop(k,None)
env['PKG_CONFIG_LIBDIR']=str(b/'sysroot/lib/pkgconfig')
env['PKG_CONFIG_PATH']=''
env['CC']=str(profile/'clang')
subprocess.run([sys.executable,str(r/'ports/nyxt/wpe/apply-patches.py'),
    str(b/'wpewebkit-2.54.1'),'jsc-darterfly-platform.patch',
    'jsc-standalone-includes.patch'],check=True)
toolchain=b/'jsc-toolchain.cmake'
toolchain.write_text(f"""set(CMAKE_SYSTEM_NAME Darterfly)
set(CMAKE_SYSTEM_PROCESSOR x86_64)
list(PREPEND CMAKE_MODULE_PATH "{r}/ports/nyxt/wpe/cmake")
set(CMAKE_C_COMPILER "{r}/ports/nyxt/wpe/target-cc.py")
set(CMAKE_CXX_COMPILER "{r}/ports/nyxt/wpe/target-cxx.sh")
set(CMAKE_AR "{profile}/llvm-ar")
set(CMAKE_RANLIB "{profile}/llvm-ranlib")
set(CMAKE_FIND_ROOT_PATH "{b}/sysroot")
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
""")
args=[profile/'cmake','-S',b/'wpewebkit-2.54.1','-B',b/'jsc-target','-G','Ninja',
 '-DCMAKE_TOOLCHAIN_FILE='+str(toolchain),'-DPORT=JSCOnly',
 '-DCMAKE_BUILD_TYPE=MinSizeRel','-DENABLE_STATIC_JSC=ON',
 '-DENABLE_JIT=OFF','-DENABLE_DFG_JIT=OFF','-DENABLE_FTL_JIT=OFF',
 '-DENABLE_C_LOOP=ON','-DENABLE_WEBASSEMBLY=OFF',
 '-DENABLE_SAMPLING_PROFILER=OFF','-DUSE_SYSTEM_MALLOC=ON',
 '-DENABLE_REMOTE_INSPECTOR=OFF','-DENABLE_UNIFIED_BUILDS=OFF','-DUSE_HEADER_MAPS=OFF',
 '-DCMAKE_C_FLAGS=-ffunction-sections -fdata-sections',
 '-DCMAKE_CXX_FLAGS=-ffunction-sections -fdata-sections']
subprocess.run(list(map(str,args)),env=env,check=True)
subprocess.run([str(profile/'ninja'),'-C',str(b/'jsc-target'),'-j8','JavaScriptCore','JavaScriptCoreJIT'],env=env,check=True)
