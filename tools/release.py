#!/usr/bin/env python3
"""Isolated release builds and evidence bundles; Python standard library only."""
import argparse
from contextlib import nullcontext
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import shutil
import signal
import statistics
import subprocess
import sys
import tarfile
import tempfile
import time
from datetime import datetime, timezone

ROOT = Path(__file__).resolve().parents[1]


def write_json(path, value):
    tmp = path.with_suffix(path.suffix + '.tmp')
    tmp.write_text(json.dumps(value, indent=2, sort_keys=True) + '\n')
    tmp.replace(path)


def sha256(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def git(*args):
    return subprocess.check_output(['git', '-C', str(ROOT), *args])


def snapshot(work, archive, epoch):
    """Capture tracked + nonignored files, including dirty edits, with stable metadata."""
    names = sorted(set(git('ls-files', '-z', '--cached', '--others', '--exclude-standard').split(b'\0')) - {b''})
    with tarfile.open(archive, 'w') as tar:
        for raw in names:
            name = os.fsdecode(raw)
            src = ROOT / name
            if src.is_symlink():
                raise ValueError(f'unsupported source symlink: {name}')
            if not src.exists():
                continue  # A tracked deletion is represented by absence.
            if src.is_symlink() or not src.is_file():
                raise ValueError(f'unsupported source entry: {name}')
            dst = work / name
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(src, dst)
            mode = 0o755 if src.stat().st_mode & 0o111 else 0o644
            dst.chmod(mode)
            os.utime(dst, (epoch, epoch))
            info = tarfile.TarInfo(name)
            info.size = dst.stat().st_size
            info.mode, info.mtime = mode, epoch
            with dst.open('rb') as stream:
                tar.addfile(info, stream)
    # Catch edits to already-dirty files too, not just changes in git status.
    for raw in names:
        name = os.fsdecode(raw)
        original, captured = ROOT / name, work / name
        if original.exists() != captured.exists():
            raise RuntimeError(f'source changed during capture: {name}')
        if captured.exists() and (original.is_symlink() or sha256(original) != sha256(captured)
                                  or bool(original.stat().st_mode & 0o111) != bool(captured.stat().st_mode & 0o111)):
            raise RuntimeError(f'source changed during capture: {name}')


def execute(command, log, cwd, env, timeout, stderr_path=None):
    """Retain all output, bound run time, and terminate child QEMUs on failure."""
    started = time.monotonic()
    record = {'command': command, 'log': str(log), 'status': 'running'}
    print(f'Running {log.stem}; log: {log}', flush=True)
    with log.open('wb') as stream, (stderr_path.open('wb') if stderr_path else nullcontext(subprocess.STDOUT)) as errors:
        process = subprocess.Popen(command, cwd=cwd, env=env, stdout=stream,
                                   stderr=errors, start_new_session=True)
        try:
            record['exit_code'] = process.wait(timeout=timeout)
            record['status'] = 'passed' if process.returncode == 0 else 'failed'
        except subprocess.TimeoutExpired:
            record['status'] = 'timeout'
            record['exit_code'] = 124
        except KeyboardInterrupt:
            record['status'] = 'interrupted'
            record['exit_code'] = 130
        finally:
            # The group may still contain an orphaned QEMU even if SBCL exited.
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                pass
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait()
    record['seconds'] = round(time.monotonic() - started, 3)
    return record


def summarize(samples):
    """Nearest-rank p95, retaining missing/error values rather than calling them zero."""
    metrics = {}
    for sample in samples:
        seen = set()
        for row in sample:
            name = row['name']
            if name in seen:
                raise ValueError(f'duplicate metric: {name}')
            seen.add(name)
            metric = metrics.setdefault(name, {'unit': row['unit'], 'values': [], 'unavailable': []})
            if metric['unit'] != row['unit']:
                raise ValueError(f'inconsistent units: {name}')
            value = row['value']
            if isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value):
                metric['values'].append(value)
            else:
                metric['unavailable'].append(value)
    for metric in metrics.values():
        values = sorted(metric['values'])
        metric['count'] = len(values)
        metric['missing'] = len(samples) - len(values) - len(metric['unavailable'])
        if values:
            metric.update(min=min(values), median=statistics.median(values),
                          p95=values[math.ceil(.95 * len(values)) - 1], max=max(values))
    return metrics


def inside(args):
    def interrupted(signum, frame):
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, interrupted)
    bundle = Path(args.bundle)
    env = os.environ.copy()
    env['CL_SOURCE_REGISTRY'] = f'{ROOT}//:{env["GUIX_ENVIRONMENT"]}/share/common-lisp//'
    env['ASDF_OUTPUT_TRANSLATIONS'] = f'/:{env["HOME"]}/.cache/common-lisp/release/'
    env['DARTERFLY_RELEASE_DIR'] = str(bundle)
    env['DARTERFLY_RELEASE_TIER'] = args.tier
    env['DARTERFLY_RELEASE_SAMPLES'] = str(args.bench)
    env['DARTERFLY_RELEASE_IDENTITY'] = str(bundle / 'image-identity.json')
    profile = Path(env['GUIX_ENVIRONMENT'])
    shutil.copyfile(profile / 'manifest', bundle / 'guix-manifest.scm')
    versions = {'profile': str(profile), 'python': sys.version}
    for tool, flag in [('sbcl', '--version'), ('qemu-system-x86_64', '--version'),
                       ('clang', '--version'), ('gcc', '--version'), ('ld.lld', '--version')]:
        versions[tool] = subprocess.check_output([tool, flag], text=True).strip()
    firmware = {}
    for name in ('ovmf_code_x64.bin', 'ovmf_vars_x64.bin'):
        path = profile / 'share/firmware' / name
        firmware[name] = {'path': str(path.resolve()), 'sha256': sha256(path)}
    write_json(bundle / 'environment.json', {'tools': versions, 'firmware': firmware})
    manifest = json.loads((bundle / 'manifest.json').read_text())
    write_json(bundle / 'image-identity.json',
               {key: manifest[key] for key in ('revision', 'dirty', 'source_date_epoch', 'source_sha256', 'pinned_guix')} |
               {'guix_profile': str(profile), 'channels_sha256': sha256(bundle / 'channels.scm')})
    sbcl = ['sbcl', '--no-sysinit', '--no-userinit', '--non-interactive', '--eval', '(require :asdf)']
    stages = []
    def stage(name, command):
        env['DARTERFLY_RELEASE_STAGE'] = name
        record = execute(command, bundle / 'logs' / (name + '.log'), ROOT, env, args.timeout)
        stages.append(dict(name=name, **record))
        write_json(bundle / 'stages.json', stages)
        if record['exit_code']:
            raise RuntimeError(f'{name}: {record["status"]}; see {record["log"]}')
    stage('tooling', ['python3', '-B', '-m', 'unittest', 'discover', '-s', 'tests', '-p', 'test_release.py'])
    stage('check', sbcl + ['--load', 'bench/check.lisp'])
    if args.tier != 'host' or args.image or args.bench:
        stage('bootstrap', sbcl + ['--load', 'tools/release.lisp'])
    tiers = ['host', 'guest', 'recovery'] if args.tier == 'all' else (['host', 'smoke'] if args.tier == 'smoke' else [args.tier])
    for tier in tiers:
        env['DARTERFLY_RELEASE_TIER'] = tier
        stage('test-' + tier, sbcl + ['--load', 'tools/release.lisp'])
    if args.image:
        stage('image', sbcl + ['--load', 'tools/release.lisp'])
        stage('image-smoke', sbcl + ['--load', 'tools/release.lisp'])
    if args.bench:
        stage('measure', sbcl + ['--load', 'tools/release.lisp'])
        samples = json.loads((bundle / 'samples.json').read_text())
        metrics = summarize(samples)
        write_json(bundle / 'metrics.json', metrics)
        required = ('boot-to-init-ms', 'console-roundtrip-ms', 'full-gc-ms', 'full-frame-ms',
                    'disk-sync-ms', 'disk-write-mb-s', 'tcp-receive-mib-s', 'free-mb', 'heap-mb',
                    'gui-key-to-draw-observed-ms')
        missing = [name for name in required if metrics.get(name, {}).get('count') != args.bench]
        if missing:
            stages.append({'name': 'metrics', 'status': 'failed', 'missing': missing, 'exit_code': 1})
            write_json(bundle / 'stages.json', stages)
            raise RuntimeError(f'required measurements unavailable: {missing}')
    return 0


def host_identity():
    result = platform.uname()._asdict()
    cpu = Path('/proc/cpuinfo').read_text().split('\n\n', 1)[0]
    fields = dict(line.split(':', 1) for line in cpu.splitlines() if ':' in line)
    fields = {k.strip(): v.strip() for k, v in fields.items()}
    result['cpu'] = {k: fields.get(k) for k in ('vendor_id', 'model name', 'cpu family', 'model', 'stepping', 'microcode', 'flags')}
    result['cpu_affinity'] = sorted(os.sched_getaffinity(0))
    result['logical_cpus'] = os.cpu_count()
    result['memory_total'] = Path('/proc/meminfo').read_text().splitlines()[0]
    result['firmware'] = {}
    for name in ('sys_vendor', 'product_name', 'product_version', 'bios_vendor', 'bios_version', 'bios_date'):
        path = Path('/sys/class/dmi/id') / name
        if os.access(path, os.R_OK):
            result['firmware'][name] = path.read_text().strip()
    return result


def run(args):
    status = git('status', '--porcelain=v1', '--untracked-files=all').decode()
    revision = git('rev-parse', 'HEAD').decode().strip()
    if status and not args.allow_dirty:
        raise ValueError('checkout is dirty; commit first, or use --allow-dirty for an explicitly unqualified development bundle')
    if args.tier != 'host' or args.image or args.bench:
        if not os.access('/dev/kvm', os.R_OK | os.W_OK):
            raise ValueError('the qemu-kvm reference platform requires read/write access to /dev/kvm')
    epoch = int(os.environ.get('SOURCE_DATE_EPOCH', git('show', '-s', '--format=%ct', 'HEAD').decode().strip()))
    stamp = datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')
    bundle = Path(args.output).resolve() if args.output else ROOT / 'build/releases' / f'{stamp}-{revision[:12]}'
    bundle.mkdir(parents=True, exist_ok=False)
    (bundle / 'logs').mkdir()
    (bundle / 'artifacts').mkdir()
    # Short socket paths; HOME and all caches are private to this run.
    workspace = Path(tempfile.mkdtemp(prefix='df-release-'))
    work = workspace / 'source'
    work.mkdir()
    home = workspace / 'home'
    home.mkdir()
    manifest = {'schema': 1, 'revision': revision, 'dirty': bool(status), 'status': 'preparing',
                'source_date_epoch': epoch, 'started_utc': stamp, 'workspace': str(workspace),
                'platform': 'qemu-kvm-x86_64', 'host': host_identity(),
                'pinned_guix': not args.current_guix, 'tier': args.tier,
                'image_requested': args.image, 'benchmark_samples_requested': args.bench,
                'qualified': False, 'bit_identical_image_verified': False}
    write_json(bundle / 'manifest.json', manifest)
    (bundle / 'source-status.txt').write_text(status)
    (bundle / 'source.patch').write_bytes(git('diff', '--binary', 'HEAD'))
    print(f'Evidence bundle: {bundle}', flush=True)
    try:
        snapshot(work, bundle / 'source.tar', epoch)
        if git('rev-parse', 'HEAD').decode().strip() != revision or git('status', '--porcelain=v1', '--untracked-files=all').decode() != status:
            raise RuntimeError('checkout changed during capture; retry to capture a consistent revision')
        manifest['source_sha256'] = sha256(bundle / 'source.tar')
        write_json(bundle / 'manifest.json', manifest)
        shutil.copyfile(work / 'release/channels.scm', bundle / 'channels.scm')
        env = os.environ.copy()
        # Do not change the invoking shell's HOME; only the child receives this HOME.
        env.update(HOME=str(home), TZ='UTC', LANG='C', LC_ALL='C', SOURCE_DATE_EPOCH=str(epoch))
        prefix = ['guix'] if args.current_guix else ['guix', 'time-machine', '-C', str(bundle / 'channels.scm'), '--']
        # Resolve channels with the real host environment; record the exact Guix used.
        channels = execute(prefix + ['describe', '-f', 'channels'], bundle / 'resolved-channels.scm',
                           work, os.environ.copy(), args.timeout, stderr_path=bundle / 'logs/channels.log')
        if channels['exit_code']:
            raise RuntimeError('Guix channel resolution failed; see resolved-channels.scm')
        command = prefix + ['shell', '-m', str(work / 'manifest.scm'), '--pure',
                            '--preserve=^(HOME|TZ|LANG|LC_ALL|SOURCE_DATE_EPOCH)$', '--',
                            'python3', '-B', 'tools/release.py', 'inside', '--bundle', str(bundle),
                            '--tier', args.tier, '--bench', str(args.bench), '--timeout', str(args.timeout)]
        if args.image:
            command.append('--image')
        result = execute(command, bundle / 'logs/environment.log', work, env, args.timeout * 10)
        manifest['environment_run'] = result
        manifest['status'] = result['status']
        manifest['qualified'] = (result['status'] == 'passed' and not status and not args.current_guix
                                 and args.tier == 'all' and args.image and args.bench >= 5)
    except (Exception, KeyboardInterrupt) as error:
        manifest['status'] = 'failed'
        manifest['error'] = str(error)
        print(str(error), file=sys.stderr)
    finally:
        # Keep nested compiler logs even when bootstrap never completed.
        if (work / 'build').exists():
            for path in (work / 'build').rglob('*.log'):
                dest = bundle / 'logs/build' / path.relative_to(work / 'build')
                dest.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(path, dest)
        manifest['artifacts'] = {str(p.relative_to(bundle)): {'sha256': sha256(p), 'bytes': p.stat().st_size}
                                 for p in sorted((bundle / 'artifacts').rglob('*')) if p.is_file()}
        manifest['finished_utc'] = datetime.now(timezone.utc).isoformat()
        write_json(bundle / 'manifest.json', manifest)
        checksums = [(sha256(p), str(p.relative_to(bundle))) for p in sorted(bundle.rglob('*'))
                     if p.is_file() and p.name != 'SHA256SUMS']
        (bundle / 'SHA256SUMS').write_text(''.join(f'{digest}  {name}\n' for digest, name in checksums))
    print(f'{manifest["status"]}: {bundle}\nRetained workspace: {workspace}', flush=True)
    return 0 if manifest['status'] == 'passed' else 1


def compare(args):
    a, b = [Path(x) for x in args.bundles]
    before, after = [json.loads((p / 'metrics.json').read_text()) for p in (a, b)]
    metadata = [json.loads((p / 'manifest.json').read_text()) for p in (a, b)]
    environments = [json.loads((p / 'environment.json').read_text()) for p in (a, b)]
    compatible = (metadata[0]['platform'] == metadata[1]['platform'] and
                  metadata[0]['host'] == metadata[1]['host'] and environments[0] == environments[1])
    report = {'comparable_environment': compatible, 'metrics': {}, 'artifacts': {}}
    for name in sorted(before.keys() & after.keys()):
        old, new = before[name], after[name]
        if old['unit'] == new['unit'] and old.get('median', 0) and 'median' in new:
            report['metrics'][name] = {'unit': old['unit'], 'before_median': old['median'],
                                      'after_median': new['median'],
                                      'median_change_percent': 100 * (new['median'] / old['median'] - 1)}
    for name in sorted(metadata[0]['artifacts'].keys() | metadata[1]['artifacts'].keys()):
        report['artifacts'][name] = (metadata[0]['artifacts'].get(name, {}).get('sha256') ==
                                      metadata[1]['artifacts'].get(name, {}).get('sha256'))
    print(json.dumps(report, indent=2))
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    for name in ('run', 'inside'):
        sub = commands.add_parser(name)
        sub.add_argument('--tier', choices=['host', 'smoke', 'guest', 'recovery', 'all'], default='all')
        sub.add_argument('--image', action='store_true')
        sub.add_argument('--bench', type=int, default=0)
        sub.add_argument('--timeout', type=int, default=14400, help='seconds per stage')
        if name == 'run':
            sub.add_argument('--allow-dirty', action='store_true')
            sub.add_argument('--current-guix', action='store_true', help='development only: use and record host channels')
            sub.add_argument('--output')
        else:
            sub.add_argument('--bundle', required=True)
    commands.add_parser('compare').add_argument('bundles', nargs=2)
    args = parser.parse_args()
    if args.command != 'compare' and (args.bench < 0 or args.timeout <= 0):
        parser.error('--bench must be nonnegative and --timeout must be positive')
    try:
        return {'run': run, 'inside': inside, 'compare': compare}[args.command](args)
    except (ValueError, RuntimeError, OSError) as error:
        print(f'release: {error}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
