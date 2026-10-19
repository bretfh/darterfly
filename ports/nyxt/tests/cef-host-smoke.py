#!/usr/bin/env python3
"""Run the Lisp/CEF integration fixture on an isolated Xvfb display."""
import argparse
import functools
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import os
from pathlib import Path
import select
import signal
import subprocess
import tempfile
import threading


class FixtureHandler(SimpleHTTPRequestHandler):
    def log_message(self, *args):
        pass


def stop(process):
    if process is None:
        return
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--runtime', type=Path, required=True)
    parser.add_argument('--log-dir', type=Path, required=True)
    parser.add_argument('--nyxt', type=Path)
    args = parser.parse_args()
    args.log_dir.mkdir(parents=True, exist_ok=True)
    read_fd, write_fd = os.pipe()
    xvfb = lisp = server = server_thread = None
    with tempfile.TemporaryDirectory(prefix='darterfly-cef-') as scratch:
        env = os.environ.copy()
        for key in ('WAYLAND_DISPLAY', 'CL_SOURCE_REGISTRY'):
            env.pop(key, None)
        env.update(
            CL_CEF_SOURCE=str(args.source.resolve()),
            CL_CEF_RUNTIME=str(args.runtime.resolve()),
            CL_CEF_LIBRARY=str(args.runtime.resolve() / 'libcl-cef.so'),
            XDG_CONFIG_HOME=scratch + '/config',
            XDG_CACHE_HOME=scratch + '/cache',
            XDG_DATA_HOME=scratch + '/data',
            ASDF_OUTPUT_TRANSLATIONS=(
                f'(:output-translations (t "{scratch}/fasl/") '
                ':ignore-inherited-configuration)'),
        )
        # NSS loads its root-certificate module dynamically from lib/nss.
        profile = env.get('GUIX_ENVIRONMENT')
        if profile:
            env['LD_LIBRARY_PATH'] = ':'.join(filter(None, [
                profile + '/lib', profile + '/lib/nss',
                env.get('LD_LIBRARY_PATH')]))
        marker = 'CEF-HOST-SMOKE-PASS'
        command = ['sbcl', '--noinform', '--no-userinit', '--non-interactive',
                   '--load', str(Path(__file__).with_suffix('.lisp').resolve())]
        if args.nyxt:
            marker = 'NYXT-CEF-HOST-PASS'
            fixture = Path(scratch) / 'fixture.html'
            fixture.write_text("<title>darter-nyxt-ready</title>"
                               "<div id='probe' style='width:123px'>"
                               "Darterfly</div>")
            server = ThreadingHTTPServer(
                ('127.0.0.1', 0),
                functools.partial(FixtureHandler, directory=scratch))
            server_thread = threading.Thread(target=server.serve_forever,
                                             daemon=True)
            server_thread.start()
            fixture_url = (f'http://127.0.0.1:{server.server_port}/fixture.html')
            command = [str(args.nyxt.resolve()), '--no-config',
                       '--no-auto-config', '--socket', scratch + '/nyxt.sock',
                       '--load', str(Path(__file__).resolve().with_name(
                           'nyxt-cef-host-smoke.lisp')), fixture_url]
        try:
            with (args.log_dir / 'xvfb.log').open('w') as xlog:
                xvfb = subprocess.Popen(
                    ['Xvfb', '-displayfd', str(write_fd), '-screen', '0',
                     '800x600x24', '-nolisten', 'tcp'],
                    pass_fds=(write_fd,), stdout=xlog, stderr=xlog,
                    start_new_session=True)
                os.close(write_fd)
                write_fd = None
                if not select.select([read_fd], [], [], 15)[0]:
                    raise RuntimeError('Xvfb did not provide a display')
                display = os.read(read_fd, 64).decode().strip()
                if not display.isdigit():
                    raise RuntimeError('Xvfb failed to start')
                env['DISPLAY'] = ':' + display
                with (args.log_dir / 'smoke.log').open('w') as log:
                    lisp = subprocess.Popen(
                        command,
                        env=env, cwd=scratch, stdout=log, stderr=log,
                        start_new_session=True)
                    result = lisp.wait(timeout=120)
                output = (args.log_dir / 'smoke.log').read_text()
                for line in output.splitlines():
                    if line.startswith(('PASS:', 'CEF-HOST-', 'NYXT-CEF-HOST-')):
                        print(line)
                if (result or marker not in output or 'Check failed:' in output
                        or 'cl-cef ui thread error:' in output):
                    print(output[-6000:])
                    raise RuntimeError(f'CEF smoke test failed: exit {result}')
        finally:
            stop(lisp)
            stop(xvfb)
            if server is not None:
                server.shutdown()
                server.server_close()
                server_thread.join(timeout=5)
            os.close(read_fd)
            if write_fd is not None:
                os.close(write_fd)


if __name__ == '__main__':
    main()
