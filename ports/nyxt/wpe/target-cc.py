#!/usr/bin/env python3
"""Explicit libsa cross compiler; link-only feature checks use real exports.

Configure executables are never run. Final guests use link-native-program.
The zero-valued image boundaries below are only for link feature checks.
"""
import os
from pathlib import Path
import subprocess
import sys
root = Path(__file__).resolve().parents[3]
build = root / 'build/wpe-assessment'
clang = (build / 'build-tools.txt').read_text().splitlines()[2]
resource = subprocess.check_output([clang, '-print-resource-dir'], text=True).strip()
args = sys.argv[1:]
cxx = "--cxx" in args
if cxx: args.remove("--cxx")
flags = ['--target=x86_64-unknown-none-elf', '-D__darterfly__',
         '-DEGL_NO_PLATFORM_SPECIFIC_TYPES', '-nostdinc', '-isystem', str(build/'sysroot/include'), '-isystem', str(root/'src/libsa/include'),
         '-isystem', resource+'/include', '-fno-stack-protector',
         '-fno-pic', '-fno-pie', '-mno-red-zone', '-ftls-model=local-exec']
if cxx:
    clang = str(Path(clang).with_name('clang++'))
    flags = ['-isystem', str(root/'build/cxx/include/c++/v1'), *flags]
# Clang's generic ELF driver defaults to a host GCC linker unless selected.
if not any(x in args for x in ['-c', '-E', '-S', '--version', '-v']):
    flags += ['-fuse-ld=lld', '-nostdlib', '-Wl,-e,main',
              '-L'+str(build/'sysroot/lib'), str(root/'build/cxx/libsa.o')]
    if cxx: flags += [str(root/'build/cxx/runtime.o')]
    for name in ['__preinit_array_start', '__preinit_array_end',
                 '__init_array_start', '__init_array_end', '__fini_array_start',
                 '__fini_array_end', '__tdata_start', '__tdata_end', '__tbss_end', '__eh_frame_start',
                 '__eh_frame_end', '__eh_frame_hdr_start', '__eh_frame_hdr_end']:
        flags += ['-Wl,--defsym,'+name+'=0']
    flags += ['-Wl,--defsym,__tls_align=16']
env = dict(os.environ)
for key in ['CPATH','C_INCLUDE_PATH','CPLUS_INCLUDE_PATH','LIBRARY_PATH']:
    env.pop(key,None)
raise SystemExit(subprocess.call([clang,*flags,*args],env=env))
