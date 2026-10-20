#!/usr/bin/env python3
"""Generate deterministic local test media; FFmpeg runs only on the host."""
from pathlib import Path
import subprocess

out = Path(__file__).resolve().parents[3]/'build/wpe-assessment'
out.mkdir(parents=True, exist_ok=True)
for name, hz, codec in [('media.webm', 440, 'libvpx'),
                        ('media-vp9.webm', 660, 'libvpx-vp9'),
                        ('media-h264.mp4', 880, 'libx264'),
                        ('media-fragmented.mp4', 880, 'libx264')]:
    mp4 = name.endswith('.mp4')
    extra = (['-profile:v', 'high', '-level:v', '1.3', '-pix_fmt', 'yuv420p',
              '-g', '24', '-movflags',
              '+frag_keyframe+empty_moov+default_base_moof'
              if name == 'media-fragmented.mp4' else '+faststart'] if mp4 else [])
    subprocess.run(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-y',
        '-f', 'lavfi', '-i', 'testsrc2=size=320x180:rate=24',
        '-f', 'lavfi', '-i', f'sine=frequency={hz}:sample_rate=48000', '-t', '3',
        '-c:v', codec, '-b:v', '300k', '-c:a', 'aac' if mp4 else 'libopus',
        '-ac', '2', *extra, str(out/name)], check=True)
subprocess.run(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-y',
    '-f', 'lavfi', '-i', 'sine=frequency=1760:sample_rate=44100', '-t', '3',
    '-c:a', 'aac', '-ac', '2', '-movflags', '+faststart',
    str(out/'media-aac.m4a')], check=True)
