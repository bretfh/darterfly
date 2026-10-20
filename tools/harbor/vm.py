#!/usr/bin/env python3
"""Private KVM review VM. Run inside `guix shell -m manifest.scm --`."""
import argparse
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import time

ROOT = Path(__file__).resolve().parents[2]
BASE = ROOT / 'build' / 'harbor-vm'


def qmp(command, arguments=None):
    with socket.socket(socket.AF_UNIX) as sock:
        sock.settimeout(10)
        sock.connect(str(BASE / 'qmp.sock'))
        stream = sock.makefile('rwb', buffering=0)
        stream.readline()
        for request in ({'execute': 'qmp_capabilities'},
                        {'execute': command, 'arguments': arguments or {}}):
            stream.write(json.dumps(request).encode() + b'\n')
            while True:
                line = stream.readline()
                if not line:
                    raise RuntimeError('QEMU closed the connection')
                reply = json.loads(line)
                if 'error' in reply:
                    raise RuntimeError(reply['error'])
                if 'return' in reply:
                    break
        return reply['return']


def start(display, installed=False):
    BASE.mkdir(parents=True, exist_ok=True)
    try:
        qmp('query-status')
    except (FileNotFoundError, ConnectionRefusedError):
        pass
    else:
        raise SystemExit('The Harbor VM is already running.')
    profile = os.environ.get('GUIX_ENVIRONMENT')
    image = ROOT / 'build' / 'harbor-live.img'
    if not profile or not shutil.which('qemu-system-x86_64'):
        raise SystemExit('Run inside guix shell -m manifest.scm --')
    if not installed and not image.exists():
        raise SystemExit('Build the image with tools/harbor/build.sh first.')
    disk = BASE / 'disposable-nvme.img'
    if installed and not disk.exists():
        raise SystemExit('No installed disk exists. Install into the disposable disk first.')
    if not disk.exists():
        with disk.open('xb') as stream:
            stream.truncate(4 * 1024**3)
    firmware = Path(profile) / 'share' / 'firmware'
    args = ['qemu-system-x86_64', '-enable-kvm', '-cpu', 'host', '-m', '4096',
            '-smp', '4', '-machine', 'q35', '-name', 'Darterfly — Harbor native',
            '-drive', f'if=pflash,format=raw,readonly=on,file={firmware}/ovmf_code_x64.bin',
            '-drive', f'if=pflash,format=raw,snapshot=on,file={firmware}/ovmf_vars_x64.bin',
            '-drive', f'if=none,id=esp,format=raw,snapshot=on,file={image}',
            '-device', 'virtio-blk-pci,drive=esp,bootindex=0',
            '-drive', f'if=none,id=disk,format=raw,file={disk}',
            '-device', 'nvme,serial=harbor-test,drive=disk',
            '-netdev', 'user,id=net0', '-device', 'virtio-net-pci,netdev=net0,romfile=',
            '-device', 'virtio-keyboard-pci', '-device', 'virtio-tablet-pci',
            '-serial', f'file:{BASE}/serial.log',
            '-qmp', f'unix:{BASE}/qmp.sock,server=on,wait=off', '-no-reboot']
    if installed:
        at = args.index('-drive', args.index('-drive', args.index('-drive') + 1) + 1)
        del args[at:at+4]
        args[args.index('nvme,serial=harbor-test,drive=disk')] = 'nvme,serial=harbor-test,drive=disk,bootindex=0'
    if display == 'sdl':
        args += ['-display', 'sdl']
    else:
        # Loopback only. No network-facing unauthenticated console.
        args += ['-display', 'none', '-vnc', '127.0.0.1:18']
    (BASE / 'command.json').write_text(json.dumps(args, indent=2) + '\n')
    with (BASE / 'qemu.log').open('w') as log:
        process = subprocess.Popen(args, stdout=log, stderr=subprocess.STDOUT,
                                   start_new_session=True)
    (BASE / 'pid').write_text(str(process.pid) + '\n')
    for _ in range(50):
        if process.poll() is not None:
            raise SystemExit((BASE / 'qemu.log').read_text())
        try:
            status = qmp('query-status')
        except (FileNotFoundError, ConnectionRefusedError):
            time.sleep(.1)
        else:
            print(f'Harbor VM PID {process.pid}: {status["status"]}')
            print('SDL window' if display == 'sdl' else 'VNC: 127.0.0.1:5918')
            return
    raise SystemExit('QMP did not become ready; inspect build/harbor-vm/qemu.log')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    launch = sub.add_parser('start')
    launch.add_argument('--display', choices=('sdl', 'vnc'), default='vnc')
    launch.add_argument('--installed', action='store_true', help='Boot the disposable installed disk without the live medium')
    sub.add_parser('status')
    sub.add_parser('stop')
    capture = sub.add_parser('shot')
    capture.add_argument('name', nargs='?', default='desktop')
    args = parser.parse_args()
    if args.command == 'start':
        start(args.display, args.installed)
    elif args.command == 'status':
        print(json.dumps(qmp('query-status'), indent=2))
    elif args.command == 'stop':
        qmp('quit')
    else:
        if Path(args.name).name != args.name:
            parser.error('Screenshot name must be a filename without directories.')
        path = BASE / (args.name + '.ppm')
        qmp('screendump', {'filename': str(path)})
        if shutil.which('convert'):
            png = path.with_suffix('.png')
            subprocess.run(['convert', str(path), str(png)], check=True)
            path.unlink()
            path = png
        print(path)


if __name__ == '__main__':
    main()
