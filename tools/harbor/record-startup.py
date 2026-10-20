#!/usr/bin/env python3
"""Record a cold live boot from QMP. Requires a stopped Harbor VM and Guix shell.
Writes unmodified PPM frames plus monotonic capture times. Does not alter disks.
"""
import json
import time
from vm import start, qmp, BASE

start('vnc')
started = time.monotonic()
frames = []
for index in range(75):
    before = time.monotonic()
    path = BASE / f'startup-{index:02}.ppm'
    qmp('screendump', {'filename': str(path)})
    frames.append({'frame': path.name, 'time': time.monotonic() - started})
    time.sleep(max(0, .08 - (time.monotonic() - before)))
(BASE / 'startup-frames.json').write_text(json.dumps(frames, indent=2) + '\n')
print(f'{len(frames)} native frames in {BASE}; timing in startup-frames.json')
