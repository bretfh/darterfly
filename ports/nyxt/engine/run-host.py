#!/usr/bin/env python3
"""Run the local CEF pixel/input fixture without user profiles or remote pages."""
import argparse
import json
import os
from pathlib import Path
import signal
import struct
import subprocess
import tempfile
import zlib


def png(raw, path):
    def chunk(name, data):
        return struct.pack('>I', len(data)) + name + data + struct.pack('>I', zlib.crc32(name + data))
    assert len(raw) == 320 * 200 * 4
    rows = bytearray()
    for y in range(200):
        rows.append(0)
        for x in range(320):
            at = (y * 320 + x) * 4
            rows.extend((raw[at+2], raw[at+1], raw[at], raw[at+3]))
    path.write_bytes(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', 320, 200, 8, 6, 0, 0, 0))
                     + chunk(b'IDAT', zlib.compress(rows)) + chunk(b'IEND', b''))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--runtime', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--strace', type=Path)
    args = parser.parse_args()
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=False)
    fixture = out / 'fixture.html'
    fixture.write_text("<!doctype html><meta charset=utf-8><title>ready</title>"
                       "<style>html,body{margin:0;width:100%;height:100%}"
                       "#target{width:100%;height:100%;background:rgb(255,0,0)}</style>"
                       "<div id=target onclick=\"this.style.background='rgb(0,255,0)';"
                       "document.title='result-'+(6*7)\"></div>")
    command = [str(args.binary.resolve()), '--ozone-platform=headless',
               '--disable-gpu', '--disable-gpu-compositing',
               '--disable-background-networking', '--disable-component-update',
               '--no-first-run', '--no-default-browser-check']
    if args.strace:
        command = [str(args.strace), '-ff', '-yy', '-s', '256', '-o', str(out/'syscalls'), *command]
    with tempfile.TemporaryDirectory(prefix='darter-cef-osr-') as tmp:
        env = os.environ.copy()
        for key in ['DISPLAY', 'WAYLAND_DISPLAY']:
            env.pop(key, None)
        env.update(CEF_PROBE_RUNTIME=str(args.runtime.resolve()), CEF_PROBE_URL=fixture.as_uri(),
                   CEF_PROBE_CACHE=tmp+'/cache', CEF_PROBE_OUTPUT=str(out),
                   XDG_CONFIG_HOME=tmp+'/config', XDG_CACHE_HOME=tmp+'/xdg-cache',
                   XDG_DATA_HOME=tmp+'/data',
                   DBUS_SESSION_BUS_ADDRESS='unix:path='+tmp+'/no-session-bus',
                   DBUS_SYSTEM_BUS_ADDRESS='unix:path='+tmp+'/no-system-bus')
        profile = env.get('GUIX_ENVIRONMENT')
        if profile:
            env['LD_LIBRARY_PATH'] = ':'.join([profile+'/lib', profile+'/lib/nss', env.get('LD_LIBRARY_PATH', '')])
        with (out/'engine.log').open('w') as log:
            proc = subprocess.Popen(command, env=env, cwd=tmp, stdout=log, stderr=log, start_new_session=True)
            try:
                code = proc.wait(timeout=120)
            except subprocess.TimeoutExpired:
                os.killpg(proc.pid, signal.SIGKILL)
                proc.wait()
                code = 124
            finally:
                # Only our own process group; never touch other browser sessions.
                try:
                    os.killpg(proc.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
        text = (out/'engine.log').read_text()
        labels = ['INITIALIZE', 'PIXELS', 'INPUT-PAINT', 'JAVASCRIPT', 'SHUTDOWN']
        passed = code == 0 and all(f'[CEF-OSR {label} PASS]' in text for label in labels)
        chromium_log = out/'chromium.log'
        diagnostics = text + (chromium_log.read_text(errors='replace') if chromium_log.exists() else '')
        passed = passed and 'Check failed:' not in diagnostics and 'FATAL:' not in diagnostics
        (out/'result.json').write_text(json.dumps({'command':command, 'exit_status':code,
            'checks':labels, 'passed':passed, 'display':'headless', 'gpu':'disabled',
            'scope':'Guix host reference, local file only; no Darterfly engine execution'}, indent=2)+'\n')
        if not passed:
            print(text[-8000:])
            raise SystemExit('CEF pixel/input probe failed')
        for name in ['before', 'after']:
            png((out/(name+'.bgra')).read_bytes(), out/(name+'.png'))
        print(text)
        print('CEF pixel/input/shutdown probe passed; artifacts:', out)


if __name__ == '__main__':
    main()
