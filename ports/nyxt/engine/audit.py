#!/usr/bin/env python3
"""Record the pinned binary boundary and observed host syscalls, not an SBOM.

The Guix dependency closure is already exported in ~/org/darterfly/ports/nyxt/sbom/.
A successful local fixture is a lower bound on the OS interface required.
"""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import re
import struct
import subprocess


def elf(path, readelf, out):
    data = path.read_bytes()
    if data[:6] != b'\x7fELF\x02\x01':
        raise ValueError(f'Expected ELF64 little endian: {path}')
    kind = struct.unpack_from('<H', data, 16)[0]
    phoff = struct.unpack_from('<Q', data, 32)[0]
    phsize, phnum = struct.unpack_from('<HH', data, 54)
    headers = [struct.unpack_from('<IIQQQQQQ', data, phoff + i*phsize)
               for i in range(phnum)]
    dynamic = subprocess.check_output([readelf, '-W', '-d', str(path)], text=True)
    versions = subprocess.check_output([readelf, '-W', '--version-info', str(path)], text=True)
    symbols = subprocess.check_output([readelf, '-W', '--dyn-syms', str(path)], text=True)
    (out/(path.name+'.dynamic.txt')).write_text(dynamic)
    (out/(path.name+'.versions.txt')).write_text(versions)
    (out/(path.name+'.symbols.txt')).write_text(symbols)
    loads = [h for h in headers if h[0] == 1]
    return {'path': str(path), 'sha256': hashlib.sha256(data).hexdigest(),
            'bytes': len(data), 'elf_type': {2:'ET_EXEC', 3:'ET_DYN'}.get(kind, kind),
            'interpreter': next((data[h[2]:h[2]+h[5]].rstrip(b'\0').decode()
                                 for h in headers if h[0] == 3), None),
            'dynamic_segment': any(h[0] == 2 for h in headers),
            'tls_bytes': sum(h[6] for h in headers if h[0] == 7),
            'load_bytes': sum(h[6] for h in loads),
            'largest_load_bytes': max((h[6] for h in loads), default=0),
            'needed': re.findall(r'\(NEEDED\).*?\[(.*?)\]', dynamic),
            'glibc_versions': sorted(set(re.findall(r'GLIBC_[0-9.]+', versions))),
            'undefined_symbols': sorted(set(re.findall(r'\bUND\s+(\S+)', symbols)))}


def traces(directory):
    calls, successes, failures = Counter(), Counter(), Counter()
    evidence = {}
    patterns = {'descriptor_passing': 'SCM_RIGHTS', 'shared_mappings': 'MAP_SHARED',
                'epoll': 'epoll_', 'eventfd': 'eventfd', 'futex': 'futex(',
                'memfd': 'memfd_create(', 'seqpacket': 'SOCK_SEQPACKET',
                'process_clone': 'clone(', 'exec': 'execve('}
    paths = sorted(directory.glob('syscalls.*'))
    for path in paths:
        for line in path.read_text(errors='replace').splitlines():
            match = re.match(r'(\w+)\(.*\)\s+=\s+(.+)', line)
            if not match:
                continue
            name, result = match.groups()
            calls[name] += 1
            failed = result.startswith('-1 ')
            if failed:
                failures[name] += 1
            elif re.match(r'-?\d|0x', result):
                successes[name] += 1
            for label, pattern in patterns.items():
                if label == 'shared_mappings' and 'PROT_WRITE' not in line:
                    continue
                if pattern in line and label not in evidence and not failed:
                    evidence[label] = {'trace':path.name, 'line':line[:2048]}
    return {'thread_or_process_trace_files':len(paths),
            'completed_call_counts':dict(sorted(calls.items())),
            'successful_call_counts':dict(sorted(successes.items())),
            'failed_call_counts':dict(sorted(failures.items())),
            'successful_examples':evidence,
            'limits':'Only completed strace lines counted; a local page, sandbox disabled. '
                     'Neither complete browser coverage nor proof every observed call is mandatory.'}


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--binary', type=Path, required=True)
    p.add_argument('--runtime', type=Path, required=True)
    p.add_argument('--trace-dir', type=Path, required=True)
    p.add_argument('--readelf', required=True)
    p.add_argument('--out', type=Path, required=True)
    a = p.parse_args()
    a.out.mkdir(parents=True, exist_ok=True)
    result = {'binaries':[elf(path.resolve(), a.readelf, a.out)
                          for path in (a.binary, a.runtime/'libcef.so')],
              'trace':traces(a.trace_dir),
              'host_result':json.loads((a.trace_dir/'result.json').read_text())}
    (a.out/'audit.json').write_text(json.dumps(result, indent=2)+'\n')
    print('Audit written:', a.out/'audit.json')


if __name__ == '__main__':
    main()
