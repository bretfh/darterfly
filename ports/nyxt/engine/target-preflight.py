#!/usr/bin/env python3
"""Measure target configuration/header failures without a full engine checkout.

This is deliberately not an engine build. It never supplies Linux defines,
Linux headers, fabricated CEF hashes, or placeholder engine symbols.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[3]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def command(argv, **kwargs):
    result = subprocess.run([str(x) for x in argv], stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, text=True,
                            timeout=120, **kwargs)
    return result.returncode, result.stdout


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--chromium', type=Path, required=True)
    p.add_argument('--cef', type=Path, required=True)
    p.add_argument('--sdk', type=Path, required=True)
    p.add_argument('--out', type=Path, required=True)
    p.add_argument('--gn', default='gn')
    p.add_argument('--clang', default='clang')
    args = p.parse_args()
    args.out = args.out.resolve()
    args.out.mkdir(parents=True, exist_ok=False)
    lock = json.loads((ROOT / 'ports/nyxt/cef-reference.json').read_text())
    report = {'scope': 'GN platform selection and CEF C API syntax only; '
                       'no engine generation, link or execution',
              'sources': {}, 'checks': []}
    for name, path, revision in (
        ('chromium', args.chromium, lock['chromium_commit']),
        ('cef', args.cef, lock['cef_commit']),
    ):
        code, head = command(['git', '-C', path, 'rev-parse', 'HEAD'])
        if code or head.strip() != revision:
            raise RuntimeError(f'{name}: expected pinned commit {revision}')
        code, dirty = command(['git', '-C', path, 'status', '--porcelain',
                               '--untracked-files=no'])
        if code or dirty:
            raise RuntimeError(f'{name}: preflight requires unmodified sources')
        report['sources'][name] = {'commit': revision,
                                   'path': str(path.resolve())}
    report['sources']['sdk'] = str(args.sdk.resolve())
    report['sources']['cef_build_header_sha256'] = sha(
        args.sdk / 'include/base/cef_build.h')
    free = shutil.disk_usage(args.chromium).free
    report['storage'] = {'available_bytes': free,
                         'upstream_minimum_bytes': 100_000_000_000,
                         'sufficient_for_full_build': free >= 100_000_000_000,
                         'source': 'docs/linux/build_instructions.md at '
                                   + lock['chromium_commit']}

    # An explicit config-only root runs the *unmodified* pinned buildconfig.
    # It avoids pretending the sparse source tree contains DEPS or generators.
    config = args.chromium / 'build/config/BUILDCONFIG.gn'
    root = args.out / 'config-root'
    (root / 'build/config').mkdir(parents=True)
    shutil.copyfile(config, root / 'build/config/BUILDCONFIG.gn')
    (root / '.gn').write_text(
        'buildconfig = "//build/config/BUILDCONFIG.gn"\n')
    (root / 'BUILD.gn').write_text('group("default") {}\n')
    report['sources']['buildconfig_sha256'] = sha(config)
    gn = str(Path(shutil.which(args.gn) or args.gn).resolve())
    clang = str(Path(shutil.which(args.clang) or args.clang).resolve())
    report['tools'] = {gn: command([gn, '--version'])[1].strip(),
                        clang: command([clang, '--version'])[1].strip()}
    commands = [('gn-platform', [gn, 'gen', root / 'out', f'--root={root}',
                                '--args=target_os="darterfly" target_cpu="x64"'])]
    code, resource = command([clang, '-print-resource-dir'])
    if code:
        raise RuntimeError('Clang resource directory unavailable')
    commands.append(('cef-capi', [
        clang, '--target=x86_64-unknown-none-elf', '-D__darterfly__',
        '-ffreestanding', '-fno-stack-protector', '-fno-pie', '-mno-red-zone',
        '-nostdinc', '-isystem', Path(resource.strip()) / 'include',
        '-isystem', ROOT / 'src/libsa/include', '-I', args.sdk.resolve(),
        '-std=c11', '-fsyntax-only', '-ferror-limit=5',
        ROOT / 'ports/nyxt/engine/osr-probe.c']))
    env = dict(os.environ)
    for key in ('CPATH', 'C_INCLUDE_PATH', 'CPLUS_INCLUDE_PATH',
                'OBJC_INCLUDE_PATH', 'LIBRARY_PATH'):
        env.pop(key, None)
    for name, argv in commands:
        code, output = command(argv, cwd=ROOT, env=env)
        log = args.out / (name + '.log')
        log.write_text(output)
        report['checks'].append({'name': name, 'command': list(map(str, argv)),
                                 'exit_code': code, 'log': log.name,
                                 'log_sha256': sha(log)})
        print(f'{name}: exit {code}; {log}')
    blocked = any(c['exit_code'] for c in report['checks']) or not \
        report['storage']['sufficient_for_full_build']
    report['status'] = 'blocked' if blocked else 'preflight-only'
    (args.out / 'result.json').write_text(json.dumps(report, indent=2) + '\n')
    return 1 if blocked else 0


if __name__ == '__main__':
    sys.exit(main())
