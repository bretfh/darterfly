#!/usr/bin/env python3
"""Cross-seed LLVM's C++ runtime against Darterfly's shared libsa headers."""
import json
import os
from pathlib import Path
import shutil
import sys
import subprocess

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / 'build/cxx'
# Guix's libcxx 19.1.7 origin, including Guix source transformations.
SOURCE = Path('/gnu/store/9s6ip95sbxhfqx63c2nd7lz9xgl701kr-llvm-project-19.1.7-checkout')

def run(args):
    # Guix may export include search paths for host packages. The target uses
    # only the explicitly selected libsa, libc++ and compiler builtin headers.
    env = {key: value for key, value in os.environ.items()
           if key not in {'CPATH', 'C_INCLUDE_PATH', 'CPLUS_INCLUDE_PATH',
                          'OBJC_INCLUDE_PATH', 'OBJCPLUS_INCLUDE_PATH'}}
    subprocess.run([str(x) for x in args], check=True, env=env)

def main():
    if not SOURCE.is_dir():
        raise SystemExit('Realize the pinned source with: guix time-machine '
                         '-C ports/cxx/channels.scm -- build --source libcxx@19.1.7')
    OUT.mkdir(parents=True, exist_ok=True)
    inc = OUT / 'include/c++/v1'
    if not inc.exists():
        shutil.copytree(SOURCE / 'libcxx/include', inc)
    inc.chmod(0o755)
    # Preserve mtimes when the configuration is unchanged: LLVM includes
    # these headers in thousands of translation units.
    for target, source in [(inc / '__config_site', ROOT / 'ports/cxx/config-site.h'),
                           (inc / '__assertion_handler', SOURCE / 'libcxx/vendor/llvm/default_assertion_handler.in'),
                           (inc / 'cxxabi.h', SOURCE / 'libcxxabi/include/cxxabi.h'),
                           (inc / '__cxxabi_config.h', SOURCE / 'libcxxabi/include/__cxxabi_config.h')]:
        data = source.read_bytes()
        if not target.exists() or target.read_bytes() != data:
            target.write_bytes(data)
    clang = shutil.which('clang')
    resource = subprocess.check_output([clang, '-print-resource-dir'], text=True).strip()
    common = [clang, '--target=x86_64-unknown-none-elf', '-c', '-O1', '-g',
              '-fno-stack-protector', '-fno-pic', '-fno-pie', '-mno-red-zone',
              '-ftls-model=local-exec', '-nostdinc', '-D__darterfly__',
              '-isystem', inc, '-isystem', ROOT / 'src/libsa/include',
              '-isystem', Path(resource) / 'include',
              '-I', SOURCE / 'libcxxabi/include', '-I', SOURCE / 'libunwind/include',
              '-I', SOURCE / 'libcxx/src']
    runtime_flags = ['-D_LIBCPP_BUILDING_LIBRARY', '-D_LIBCPP_HAS_CLOCK_GETTIME',
              '-D_LIBCXXABI_BUILDING_LIBRARY', '-DLIBCXX_BUILDING_LIBCXXABI', '-D_LIBCXXABI_USE_LLVM_UNWINDER',
              '-DHAVE___CXA_THREAD_ATEXIT_IMPL', '-D_LIBUNWIND_IS_BAREMETAL',
              '-D_LIBUNWIND_IS_NATIVE_ONLY']
    abi = '''cxa_aux_runtime cxa_default_handlers cxa_demangle cxa_exception_storage
             cxa_guard cxa_handlers cxa_vector cxa_virtual stdlib_exception
             stdlib_stdexcept stdlib_typeinfo abort_message fallback_malloc
             private_typeinfo stdlib_new_delete cxa_exception cxa_personality
             cxa_thread_atexit'''.split()
    cxx = '''new_handler new_helpers verbose_abort vector string memory algorithm
             stdexcept exception typeinfo mutex mutex_destructor
             condition_variable condition_variable_destructor thread chrono
             system_error error_category future call_once random hash shared_mutex regex locale ios ios.instantiations iostream strstream'''.split()
    sources = [SOURCE / 'libcxxabi/src' / (x + '.cpp') for x in abi]
    sources += [SOURCE / 'libcxx/src' / (x + '.cpp') for x in cxx]
    sources += [SOURCE / 'libunwind/src' / x for x in
                ['libunwind.cpp', 'UnwindLevel1.c', 'UnwindLevel1-gcc-ext.c',
                 'UnwindRegistersRestore.S', 'UnwindRegistersSave.S']]
    objects = []
    for src in sources:
        obj = OUT / (src.parent.parent.name + '-' + src.stem + '.o')
        print(src.name, flush=True)
        flags = ['-std=c++20'] if src.suffix == '.cpp' else []
        if src.parent.parent.name == 'libunwind' and src.suffix == '.cpp':
            flags += ['-fno-exceptions', '-fno-rtti']
        run(common + runtime_flags + flags + [src, '-o', obj])
        objects.append(obj)
    (OUT / 'objects.list').write_text(''.join(p.name + '\n' for p in objects))
    run(['ld.lld', '-r', *objects, '-o', OUT / 'runtime.o'])
    if '--probe' in sys.argv:
        probes = []
        for name in ['native-cxx-probe.cpp', 'native-cxx-other.cpp']:
            obj = OUT / (Path(name).stem + '.o')
            run(common + ['-std=c++20', ROOT / 'tests' / name, '-o', obj])
            probes.append(obj)
        run(['ld.lld', '-r', *probes, '-o', OUT / 'probe.o'])
        run(common + [ROOT / 'src/libsa/crt0.S', '-o', OUT / 'crt0.o'])
    (OUT / 'provenance.json').write_text(json.dumps({
        'source': str(SOURCE), 'version': '19.1.7',
        'compiler': subprocess.check_output([clang, '--version'], text=True),
        'sources': [str(p.relative_to(SOURCE)) for p in sources],
        'linker': subprocess.check_output(['ld.lld', '--version'], text=True),
        'flags': [str(x) for x in common[1:]], 'runtime_flags': runtime_flags}, indent=2) + '\n')

if __name__ == '__main__':
    main()
