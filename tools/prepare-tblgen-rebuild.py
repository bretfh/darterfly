#!/usr/bin/env python3
"""Export a source-only clang-tblgen build closure for execution in Darterfly.

The Ninja graph/configuration is a declared bootstrap input. No object or
archive is copied into the source bundle. All compilation happens in the guest.
"""
import hashlib
import importlib.util
import json
from pathlib import Path
import shlex
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('native', ROOT / 'tools/build-native-clang.py')
native = importlib.util.module_from_spec(spec)
spec.loader.exec_module(native)
SOURCE, BUILD = native.SOURCE, native.OUT
OUT = ROOT / 'build/tblgen-rebuild'
TREE = OUT / 'root'

def lisp(value):
    if isinstance(value, str):
        return '"' + value.replace('\\', '\\\\').replace('"', '\\"') + '"'
    return '(' + ' '.join(lisp(x) for x in value) + ')'

def mapped(path):
    path = str(path)
    for before, after in [(str(SOURCE), '/usr/src/llvm-project'),
                          (str(BUILD), '/usr/build/llvm'),
                          (str(ROOT / 'build/cxx/include/c++/v1'), '/usr/include/c++/v1'),
                          (str(ROOT), '/usr/src/darterfly')]:
        if path.startswith(before + '/') or path == before:
            return after + path[len(before):]
    if '/lib/clang/' in path and path.endswith('/include'):
        return '/usr/lib/clang/19/include'
    if not path.startswith('/'):
        return path
    raise ValueError('Undeclared absolute input: ' + path)

def object_path(name):
    return '/work/tblgen/objects/' + name

def frontend(command):
    words = shlex.split(command)
    source = words[words.index('-c') + 1]
    output = words[words.index('-o') + 1]
    language = 'assembler-with-cpp' if source.endswith('.S') else ('c++' if source.endswith('.cpp') else 'c')
    args = ['-cc1', '-triple', 'x86_64-unknown-none-elf', '-x', language,
            '-mrelocation-model', 'static', '-disable-red-zone',
            '-ftls-model=local-exec', '-nostdsysteminc', '-nobuiltininc',
            '-fgnuc-version=4.2.1', '-target-cpu', 'x86-64', '-funwind-tables=2',
            '-mconstructor-aliases', '-fmath-errno', '-ffp-contract=on']
    ignored = {'-c', '-o', '-MD', '-MT', '-MF', '-g', '-nostdinc', '-fno-pic',
               '-fno-pie', '-mno-red-zone', '-ftls-model=local-exec',
               '-fno-stack-protector', '-pedantic', '-fdiagnostics-color',
               '-fno-exceptions', '-fno-common'}
    i = 1
    while i < len(words):
        a = words[i]
        if a in ('-c', '-o', '-MT', '-MF'):
            i += 2; continue
        if a in ('-isystem', '-I', '-include'):
            args += [a, mapped(words[i+1])]; i += 2; continue
        if a.startswith('-I'):
            args += ['-I', mapped(a[2:])]
        elif a.startswith('-D'):
            args.append(a)
        elif a.startswith('-W') or a in ignored or a.startswith('--target='):
            pass
        elif a == '-funwind-tables':
            args.append('-funwind-tables=2')
        elif a == '-mavx512vl':
            args += ['-target-feature', '+avx512vl']
        elif a.startswith(('-std=', '-O')) or a in ('-fno-rtti', '-fvisibility-inlines-hidden',
                                                   '-ffunction-sections', '-fdata-sections'):
            args.append(a)
        else:
            raise ValueError('Untranslated compiler argument: ' + a)
        i += 1
    args += ['-E' if language == 'assembler-with-cpp' else '-emit-obj', mapped(source), '-o',
             object_path(output) + ('.s' if language == 'assembler-with-cpp' else '')]
    commands = [args]
    if language == 'assembler-with-cpp':
        commands.append(['-cc1as', '-triple', 'x86_64-unknown-none-elf', '-filetype', 'obj',
                         object_path(output)+'.s', '-o', object_path(output)])
    return [mapped(source), object_path(output), commands]

def main():
    # A failed preparation must not leave a usable stale plan.
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT/'plan.sexp').unlink(missing_ok=True)
    (OUT/'inputs.json').unlink(missing_ok=True)
    inputs = json.loads((BUILD/'bin/darter-clang-tblgen.o.inputs.json').read_text())
    database = json.loads(subprocess.check_output([native.NINJA, '-C', str(BUILD), '-t', 'compdb'], text=True))
    database = {entry['output']: entry for entry in database}
    groups, objects, direct = [], [], []
    for name in dict.fromkeys(inputs):
        if name.endswith('.a'):
            query = subprocess.check_output([native.NINJA, '-C', str(BUILD), '-t', 'query', name], text=True)
            members = [line.strip() for line in query.split('  outputs:')[0].splitlines()[2:]
                       if line.strip().endswith('.o')]
            assert members, name
            groups.append(['/work/tblgen/'+Path(name).name, [object_path(x) for x in members]])
            objects += members
        else:
            direct.append(object_path(name)); objects.append(name)
    jobs = [frontend(database[name]['command']) for name in objects]
    dependencies = subprocess.check_output(
        [native.NINJA, '-C', str(BUILD), '-t', 'deps', *objects], text=True)
    generated = sorted({line.strip() for line in dependencies.splitlines()
                        if line.strip().startswith(str(BUILD) + '/')
                        and not line.strip().endswith('.o')})
    runtime = json.loads((ROOT/'build/cxx/provenance.json').read_text())
    runtime_objects = []
    common = ['-cc1', '-triple', 'x86_64-unknown-none-elf', '-mrelocation-model', 'static',
              '-disable-red-zone', '-ftls-model=local-exec', '-nostdsysteminc', '-nobuiltininc',
              '-fgnuc-version=4.2.1', '-target-cpu', 'x86-64', '-funwind-tables=2',
              '-mconstructor-aliases', '-fmath-errno', '-ffp-contract=on',
              '-O1', '-D__darterfly__', '-isystem', '/usr/include/c++/v1', '-isystem',
              '/usr/src/darterfly/src/libsa/include', '-isystem', '/usr/lib/clang/19/include',
              '-I', '/usr/src/llvm-project/libcxxabi/include', '-I', '/usr/src/llvm-project/libunwind/include',
              '-I', '/usr/src/llvm-project/libcxx/src', *runtime['runtime_flags']]
    for source in runtime['sources'] + ['CRT']:
        src = mapped(SOURCE/source) if source != 'CRT' else '/usr/src/darterfly/src/libsa/crt0.S'
        obj = '/work/tblgen/objects/runtime/' + (source.replace('/', '_') if source != 'CRT' else 'crt0') + '.o'
        if source != 'CRT': runtime_objects.append(obj)
        language = 'assembler-with-cpp' if src.endswith('.S') else ('c++' if src.endswith('.cpp') else 'c')
        args = common + ['-x', language]
        if language == 'c++':
            args += ['-std=c++20']
            args += ['-fno-rtti'] if source.startswith('libunwind/') else ['-fcxx-exceptions', '-fexceptions']
        args += ['-E' if language == 'assembler-with-cpp' else '-emit-obj', src, '-o',
                 obj + ('.s' if language == 'assembler-with-cpp' else '')]
        commands = [args]
        if language == 'assembler-with-cpp':
            commands.append(['-cc1as', '-triple', 'x86_64-unknown-none-elf', '-filetype', 'obj', obj+'.s', '-o', obj])
        jobs.append([src, obj, commands])
    groups.append(['/work/tblgen/runtime.a', runtime_objects])
    # Source bundle is recreated; the large persistent guest disk is separate.
    if TREE.exists():
        # Guix source directories are read-only; only our copied tree is changed.
        for directory in TREE.rglob('*'):
            if directory.is_dir(): directory.chmod(0o755)
        TREE.chmod(0o755)
        shutil.rmtree(TREE)
    TREE.mkdir(parents=True)
    roots = ['llvm/include', 'llvm/lib/Support', 'llvm/lib/TableGen', 'llvm/lib/Demangle',
             'clang/include', 'clang/utils/TableGen', 'clang/lib/Support',
             'libcxx/src', 'libcxx/include', 'libcxxabi/src', 'libcxxabi/include',
             'libunwind/src', 'libunwind/include']
    for sub in roots:
        shutil.copytree(SOURCE/sub, TREE/('usr/src/llvm-project/'+sub))
    for name in generated:
        file = Path(name)
        if file.suffix not in ('.h', '.inc', '.def'):
            raise ValueError('Unexpected generated dependency: '+name)
        dest = TREE / mapped(file).lstrip('/')
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(file, dest)
    for file in TREE.rglob('*'):
        if file.is_dir(): file.chmod(0o755)
        if file.is_file() and file.suffix in ('.o', '.a', '.so'):
            raise ValueError('Binary in source closure: '+str(file))
    hashes = {str(p.relative_to(TREE)): hashlib.sha256(p.read_bytes()).hexdigest()
              for p in sorted(TREE.rglob('*')) if p.is_file()}
    # These configured/public headers and native tools are staged by the harness.
    for directory in ['build/cxx/include/c++/v1', 'build/clang/lib/clang/19/include', 'src/libsa']:
        for p in sorted((ROOT/directory).rglob('*')):
            if p.is_file(): hashes[str(p.relative_to(ROOT))] = hashlib.sha256(p.read_bytes()).hexdigest()
    for name in ['build/clang/clang', 'build/lld/ld.lld', 'build/llvm-tools/llvm-ar']:
        hashes[name] = hashlib.sha256((ROOT/name).read_bytes()).hexdigest()
    plan = [jobs, groups, direct, '/work/tblgen/objects/runtime/crt0.o']
    identity = hashlib.sha256((json.dumps(hashes,sort_keys=True)+lisp(plan)).encode()).hexdigest()
    (OUT/'inputs.json').write_text(json.dumps({'source':str(SOURCE), 'sha256':hashes,
        'plan_id':identity, 'translation_units':len(jobs),
        'observed_generated_dependencies':[mapped(p) for p in generated], 'bootstrap':'Ninja graph and configured/generated headers'},indent=2)+'\n')
    (OUT/'plan.sexp').write_text(lisp([identity,*plan])+'\n')
    print(f'{len(jobs)} translation units, {len(groups)} archives; plan {identity}')

def verify():
    """Reject changed preparation inputs before constructing a fresh guest disk."""
    record = json.loads((OUT/'inputs.json').read_text())
    for name, expected in record['sha256'].items():
        path = (TREE if name.startswith('usr/') else ROOT) / name
        if hashlib.sha256(path.read_bytes()).hexdigest() != expected:
            raise ValueError('Prepared input changed; prepare again: ' + name)
    if not (OUT/'plan.sexp').read_text().startswith('("' + record['plan_id'] + '" '):
        raise ValueError('Plan and input record do not match')
    print('Prepared source/header/tool hashes verified')

if __name__ == '__main__':
    if sys.argv[1:] == ['--verify']:
        verify()
    elif sys.argv[1:]:
        raise SystemExit('usage: prepare-tblgen-rebuild.py [--verify]')
    else:
        main()
