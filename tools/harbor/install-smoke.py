#!/usr/bin/env python3
"""Install a fresh Harbor live session into this launcher's disposable NVMe disk.
Requires --erase-disposable-disk. Never attaches or addresses host block devices.
"""
import argparse
import time
from pathlib import Path
from vm import BASE, qmp
from smoke import PAPER, wait_pixel, click, frame, pixel, shot

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--erase-disposable-disk', action='store_true', required=True)
parser.parse_args()
expected = (BASE / 'disposable-nvme.img').resolve()
blocks = qmp('query-block')
target = next(block for block in blocks if block['device'] == 'disk')
assert Path(target['inserted']['file']).resolve() == expected
assert expected.is_file() and expected.stat().st_size == 4 * 1024**3
assert any(block['device'] == 'esp' for block in blocks), 'A live medium must be present'
wait_pixel(900, 450, PAPER, 'live installer ready', timeout=90)
click(788, 532)
time.sleep(.5)
r, g, b = pixel(frame(), 866, 524)
assert r > g + 35 and g > b, 'Explicit destructive review must be visible'
shot('qa-install-target')
click(866, 532)
start = time.monotonic()
shot('qa-install-progress')
while time.monotonic() - start < 180:
    color = pixel(frame(), 720, 524)
    # Keep Exploring spans this point only on the successful completion page.
    if color and color != PAPER and max(color) - min(color) < 25:
        time.sleep(.5)
        shot('qa-install-complete')
        print('PASS: installer reached completion on the disposable disk', flush=True)
        break
    time.sleep(1)
else:
    shot('qa-install-timeout')
    raise SystemExit('Installation did not reach completion; inspect screenshot/serial output')
# The completion page's explicit shutdown action flushes the installed filesystem.
click(874, 532)
print('Requested guest shutdown. Start vm.py with --installed for first boot.', flush=True)
