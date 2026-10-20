#!/usr/bin/env python3
"""Verify actual QEMU HDA output contains the requested fixture tones."""
import json
import math
import struct
import sys
import wave

with wave.open(sys.argv[1]) as audio:
    assert audio.getsampwidth() == 2, 'Expected signed 16-bit PCM'
    rate, channels = audio.getframerate(), audio.getnchannels()
    raw = audio.readframes(audio.getnframes())
values = struct.unpack('<'+'h'*(len(raw)//2), raw)
mono = values[::channels]
assert len(mono) >= 5*rate, 'Audio capture too short to qualify fixture playback'
levels = {}
for frequency in (list(map(int, sys.argv[2:])) or [440, 660]):
    angle = 2*math.pi*frequency/rate
    cosine = [math.cos(angle*i) for i in range(rate)]
    sine = [math.sin(angle*i) for i in range(rate)]
    level = 0
    for start in range(0, len(mono)-rate+1, rate//2):
        window = mono[start:start+rate]
        real = sum(x*y for x,y in zip(window, cosine))
        imag = sum(x*y for x,y in zip(window, sine))
        level = max(level, 2*math.hypot(real, imag)/rate)
    assert level > 300, f'Missing decoded {frequency} Hz audio: amplitude {level}'
    levels[str(frequency)] = round(level, 2)
print('HDA CAPTURE PASS '+json.dumps({'seconds':len(mono)/rate,
      'sample_rate':rate,'channels':channels,'tone_amplitudes':levels}))
