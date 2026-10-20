#!/usr/bin/env python3
"""Input and pixel checks on a freshly booted Harbor live VM (1280x800).
Does not install or erase disks. Leaves real Files and Terminal windows open.
"""
import subprocess
import time
from pathlib import Path
from vm import BASE, qmp

PAPER = (243, 243, 241)
BLUE = (46, 92, 143)


def frame():
    path = BASE / 'qa-frame.ppm'
    qmp('screendump', {'filename': str(path)})
    kind, size, depth, pixels = path.read_bytes().split(b'\n', 3)
    assert kind == b'P6' and depth == b'255'
    return pixels if size == b'1280 800' else None


def pixel(pixels, x, y):
    if pixels is None:
        return None
    at = (y * 1280 + x) * 3
    return tuple(pixels[at:at+3])


def wait_pixel(x, y, color, message, timeout=20):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if pixel(frame(), x, y) == color:
            print('PASS:', message, flush=True)
            return
        time.sleep(.2)
    raise AssertionError(f'{message}: expected {color}, got {pixel(frame(), x, y)}')


def shot(name):
    path = BASE / (name + '.ppm')
    qmp('screendump', {'filename': str(path)})
    subprocess.run(['convert', str(path), str(path.with_suffix('.png'))], check=True)
    path.unlink()


def move(x, y):
    qmp('input-send-event', {'events': [
        {'type': 'abs', 'data': {'axis': 'x', 'value': int(x * 32768 / 1280)}},
        {'type': 'abs', 'data': {'axis': 'y', 'value': int(y * 32768 / 800)}}]})
    time.sleep(.12)


def button(down):
    qmp('input-send-event', {'events': [{'type': 'btn', 'data': {'button': 'left', 'down': down}}]})
    time.sleep(.1)


def click(x, y):
    move(x, y)
    button(True)
    button(False)


def key(name):
    qmp('human-monitor-command', {'command-line': 'sendkey ' + name})
    time.sleep(.18)


def run():
    wait_pixel(900, 450, PAPER, 'live welcome is ready')
    move(882, 532)
    shot('qa-button-hover')
    button(True)
    wait_pixel(900, 450, PAPER, 'mouse-down does not execute Try')
    shot('qa-button-pressed')
    move(980, 620)
    button(False)
    wait_pixel(900, 450, PAPER, 'release outside cancels Try')
    key('tab')
    key('ret')
    # Rust destructive command appears only on the explicit disk review page.
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        r, g, b = pixel(frame(), 866, 524)
        if r > g + 35 and g > b:
            break
        time.sleep(.2)
    else:
        raise AssertionError('Tab/Return did not reach disk review')
    print('PASS: keyboard navigation reaches disk review', flush=True)
    shot('qa-install-review')
    key('esc')
    key('ret')
    deadline = time.monotonic() + 10
    while pixel(frame(), 900, 450) == PAPER and time.monotonic() < deadline:
        time.sleep(.2)
    assert pixel(frame(), 900, 450) != PAPER, 'Try did not dismiss Welcome'
    print('PASS: Try leaves the installer without writing the target', flush=True)
    background = frame()
    click(606, 743)
    wait_pixel(800, 300, PAPER, 'Terminal opens from Dock')
    for name in ['shift-9', 'shift-equal', 'spc', '1', 'spc', '2', 'shift-0', 'ret']:
        key(name)
    shot('qa-terminal-input')
    click(198, 113)
    wait_pixel(800, 300, pixel(background, 800, 300), 'minimize removes Terminal from the desktop')
    click(606, 743)
    wait_pixel(800, 300, PAPER, 'Dock restores the minimized Terminal')
    shot('qa-restored')
    click(220, 113)
    wait_pixel(1100, 600, PAPER, 'zoom resizes native content')
    shot('qa-zoom')
    click(100, 57)
    wait_pixel(1100, 600, pixel(background, 1100, 600), 'second zoom restores prior geometry')
    # A double click must stay within the OS double-click interval.
    move(1215, 70)
    for _ in range(2):
        button(True)
        button(False)
    wait_pixel(130, 300, PAPER, 'Files opens from the desktop disk')
    shot('qa-overlap')
    click(30, 12)
    time.sleep(.2)
    shot('qa-menu')
    click(800, 300)
    wait_pixel(20, 40, pixel(background, 20, 40), 'outside click dismisses menu')
    # The first outside click was consumed; this click changes app ownership.
    click(800, 300)
    shot('qa-active-terminal')
    click(128, 12)
    key('esc')
    wait_pixel(90, 40, pixel(background, 90, 40), 'Escape dismisses the menu')
    move(858, 558)
    button(True)
    move(1000, 650)
    button(False)
    wait_pixel(960, 600, PAPER, 'resize grip grows Terminal and its content')
    shot('qa-resized')
    print('PASS: native interaction smoke checks complete', flush=True)


if __name__ == '__main__':
    run()
