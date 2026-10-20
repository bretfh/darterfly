#!/usr/bin/env python3
"""Menu geometry and interaction checks on a fresh live Harbor welcome."""
from smoke import move, button, click, key, wait_pixel, shot, frame, pixel, PAPER


def run():
    wait_pixel(900, 450, PAPER, 'fresh welcome')
    before = frame()
    click(30, 12)
    wait_pixel(12, 25, PAPER, 'selected heading reaches the bottom of the bar')
    wait_pixel(12, 26, PAPER, 'popup meets its heading with a square upper-left corner')
    wait_pixel(219, 26, PAPER, 'popup upper-right corner is square')
    wait_pixel(230, 20, pixel(before, 230, 20), 'popup shadow does not darken the menu bar')
    move(100, 72)
    wait_pixel(20, 72, (211, 212, 210), 'system menu highlights Generations inside its inset')
    shot('qa-refined-menu')
    move(128, 12)
    wait_pixel(175, 130, pixel(before, 175, 130), 'hover replaces the system popup with the shorter File menu')
    wait_pixel(120, 40, PAPER, 'File popup is anchored under its heading')
    shot('qa-menu-hover-switch')
    key('right')
    wait_pixel(160, 40, PAPER, 'Right opens Edit')
    key('left')
    wait_pixel(120, 40, (211, 212, 210), 'Left returns to File with keyboard selection')
    key('esc')
    wait_pixel(120, 40, pixel(before, 120, 40), 'Escape closes popup')
    move(128, 12); button(True); move(150, 43)
    wait_pixel(900, 450, PAPER, 'dragging to Close has not executed it')
    shot('qa-menu-drag-selection')
    button(False)
    # The welcome content must disappear; sample the restored background for
    # comparison after reopening rather than assuming a flat-blue desktop.
    import time
    deadline = time.monotonic() + 10
    while pixel(frame(), 900, 450) == PAPER and time.monotonic() < deadline:
        time.sleep(.2)
    assert pixel(frame(), 900, 450) != PAPER, 'Close did not dismiss Welcome'
    print('PASS: release executes Close Window', flush=True)
    move(1218, 172)
    for _ in range(2): button(True); button(False)
    wait_pixel(900, 450, PAPER, 'installer can be reopened')
    print('PASS: refined menu input checks complete', flush=True)


if __name__ == '__main__':
    run()
