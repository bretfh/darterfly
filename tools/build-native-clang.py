#!/usr/bin/env python3
"""Cross-seed the upstream Clang frontend for Darterfly's shared libsa."""
import argparse
import hashlib
import json
import importlib.util
import os
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('cxx', ROOT / 'tools/build-cxx-runtime.py')
cxx = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cxx)
SOURCE = cxx.SOURCE
OUT = ROOT / 'build/clang'
HOST = ROOT / 'build/clang-host14'
CMAKE = '/gnu/store/c8zkkq4dwblbvkg2589sllnzpnk2nfav-cmake-4.1.3/bin/cmake'
NINJA = '/gnu/store/248kk7119nrvq9y7k2dzbaz0qv96kbqw-ninja-1.13.2/bin/ninja'

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--skip-prerequisites', action='store_true',
                        help='Reuse already built host generators and C++ runtime')
    args = parser.parse_args()
    if not SOURCE.is_dir():
        raise SystemExit('Realize the LLVM source described in ports/cxx/README.org')
    if not args.skip_prerequisites:
        host_env = ['guix', 'shell', '--pure', '-m',
                    str(ROOT / 'ports/clang/host-manifest.scm'), '--']
        subprocess.run(host_env + ['cmake', '-S', str(SOURCE / 'llvm'),
            '-B', str(HOST), '-G', 'Ninja', '-DCMAKE_BUILD_TYPE=Release',
            '-DLLVM_ENABLE_PROJECTS=clang', '-DLLVM_TARGETS_TO_BUILD=X86',
            '-DLLVM_INCLUDE_TESTS=OFF', '-DLLVM_INCLUDE_BENCHMARKS=OFF',
            '-DLLVM_ENABLE_ZSTD=OFF', '-DLLVM_ENABLE_ZLIB=OFF',
            '-DLLVM_ENABLE_LIBXML2=OFF'], check=True)
        subprocess.run(host_env + ['ninja', '-C', str(HOST), '-j20',
                                   'clang-tblgen', 'llvm-tblgen'], check=True)
        cxx.run(['python3', ROOT / 'tools/build-cxx-runtime.py', '--probe'])
    OUT.mkdir(parents=True, exist_ok=True)
    clang = shutil.which('clang')
    resource = subprocess.check_output([clang, '-print-resource-dir'], text=True).strip()
    flags = f'-nostdinc -isystem {ROOT}/build/cxx/include/c++/v1 -isystem {ROOT}/src/libsa/include -isystem {resource}/include -D__darterfly__ -fno-pic -fno-pie -mno-red-zone -ftls-model=local-exec -fno-stack-protector -include ctype.h'
    toolchain = OUT / 'toolchain.cmake'
    toolchain.write_text(f'''set(CMAKE_SYSTEM_NAME FreeBSD)
set(CMAKE_SYSTEM_PROCESSOR x86_64)
set(CMAKE_C_COMPILER "{clang}")
set(CMAKE_CXX_COMPILER "{shutil.which('clang++')}")
set(CMAKE_C_COMPILER_TARGET x86_64-unknown-none-elf)
set(CMAKE_CXX_COMPILER_TARGET x86_64-unknown-none-elf)
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)
set(CMAKE_C_FLAGS_INIT "{flags}")
set(CMAKE_CXX_FLAGS_INIT "{flags}")
set(CMAKE_SKIP_RPATH ON)
''')
    options = dict(CMAKE_TOOLCHAIN_FILE=toolchain, CMAKE_MAKE_PROGRAM=NINJA,
        CMAKE_C_FLAGS=flags, CMAKE_CXX_FLAGS=flags,
        CMAKE_BUILD_TYPE='MinSizeRel', LLVM_ENABLE_PROJECTS='clang',
        LLVM_EXTERNAL_PROJECTS='darter_cc1',
        LLVM_EXTERNAL_DARTER_CC1_SOURCE_DIR=ROOT / 'ports/clang',
        LLVM_TARGETS_TO_BUILD='X86', LLVM_HOST_TRIPLE='x86_64-unknown-none-elf',
        LLVM_DEFAULT_TARGET_TRIPLE='x86_64-unknown-none-elf',
        LLVM_TABLEGEN=HOST / 'bin/llvm-tblgen', CLANG_TABLEGEN=HOST / 'bin/clang-tblgen',
        LLVM_INCLUDE_TESTS='OFF', LLVM_INCLUDE_BENCHMARKS='OFF',
        LLVM_ENABLE_ZSTD='OFF', LLVM_ENABLE_ZLIB='OFF', LLVM_ENABLE_LIBXML2='OFF',
        LLVM_ENABLE_TERMINFO='OFF', LLVM_ENABLE_LIBEDIT='OFF', LLVM_ENABLE_LIBPFM='OFF',
        LLVM_ENABLE_BACKTRACES='OFF', LLVM_ENABLE_CRASH_OVERRIDES='OFF',
        LLVM_ENABLE_PIC='OFF', LLVM_ENABLE_THREADS='ON', LLVM_ENABLE_EH='OFF',
        LLVM_ENABLE_RTTI='OFF', LLVM_ENABLE_PLUGINS='OFF',
        LLVM_BUILD_TOOLS='OFF', CLANG_BUILD_TOOLS='OFF',
        CLANG_ENABLE_STATIC_ANALYZER='OFF', CLANG_ENABLE_ARCMT='OFF',
        CLANG_ENABLE_OBJC_REWRITER='OFF', CLANG_PLUGIN_SUPPORT='OFF',
        HAVE_SYSEXITS_H=1, HAVE_FENV_H='OFF', HAVE_DLOPEN='OFF',
        HAVE_REGISTER_FRAME='OFF', HAVE_DEREGISTER_FRAME='OFF',
        HAVE_UNW_ADD_DYNAMIC_FDE='OFF', LLVM_ENABLE_ASSERTIONS='OFF', LLVM_ENABLE_DUMP='OFF')
    cxx.run([CMAKE, '-S', SOURCE / 'llvm', '-B', OUT, '-G', 'Ninja',
             *[f'-D{k}={v}' for k, v in options.items()]])
    cxx.run([NINJA, '-C', OUT, '-j20', 'darter-clang'])
    env = os.environ.copy()
    profile = os.environ['GUIX_ENVIRONMENT']
    env['CL_SOURCE_REGISTRY'] = f'{ROOT}//:{profile}/share/common-lisp//'
    env['ASDF_OUTPUT_TRANSLATIONS'] = f'/:{Path.home()}/.cache/common-lisp/darterfly/'
    subprocess.run(['sbcl', '--dynamic-space-size', '4096', '--no-userinit',
                    '--script', str(ROOT / 'ports/clang/link-seed.lisp')],
                   check=True, env=env, cwd=ROOT)
    seed = OUT / 'clang'
    (OUT / 'provenance.json').write_text(json.dumps({
        'source': str(SOURCE), 'llvm_version': '19.1.7',
        'target': 'x86_64-unknown-none-elf',
        'compiler': subprocess.check_output([clang, '--version'], text=True),
        'cmake': CMAKE, 'ninja': NINJA, 'host_generators': str(HOST),
        'options': {k: str(v) for k, v in options.items()},
        'sha256': hashlib.sha256(seed.read_bytes()).hexdigest(),
        'size': seed.stat().st_size,
        'link': 'host LLD archive/COMDAT resolution, Lisp final link with shared libsa'
    }, indent=2) + '\n')

if __name__ == '__main__':
    main()
