#!/usr/bin/env python3
"""Adversarial native control review via QMP; run on fresh live Welcome.
Loads a developer-only window. Does not install, save a generation, or alter settings.
Captures actual guest pixels and reads its action/state trace from the serial console.
"""
import importlib.util
import re
import time
from pathlib import Path
from smoke import click, move, button, key, shot, wait_pixel, PAPER
from vm import BASE, qmp

spec = importlib.util.spec_from_file_location('guest_input', Path(__file__).with_name('guest-input.py'))
guest_input = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guest_input)


def trace():
    return (BASE / 'serial.log').read_text(errors='replace')


def events():
    return re.findall(r'HARBOR-CONTROL (.*?)(?=HARBOR-CONTROL |\Z)', trace(), re.S)


def state():
    entry = events()[-1]
    return {name.lower(): value for name, value in re.findall(
        r':(TEXT|CHOICE|CHECKED|SLIDER|ENABLED|LONG|ACTIONS|ERROR)\s+("(?:[^"\\]|\\.)*"|[^\s()]+)', entry)}


def expect(message, **values):
    until = time.monotonic() + 8
    while time.monotonic() < until:
        actual = state()
        if all(actual.get(k) == str(v) for k, v in values.items()):
            print('PASS:', message, flush=True)
            return
        time.sleep(.1)
    raise AssertionError(f'{message}: wanted {values}, got {actual}')


def unchanged(message, count):
    time.sleep(.4)
    assert len(events()) == count, message + ': unexpected action'
    print('PASS:', message, flush=True)


def capture(name):
    time.sleep(.45)  # QMP input enqueue is not completion of the guest paint.
    shot(name)


def hold(name, down):
    qmp('input-send-event', {'events': [{'type': 'key', 'data': {
        'down': down, 'key': {'type': 'qcode', 'data': name}}}]})
    time.sleep(.15)


def query():
    # The fixture adds a fifth app tile; Terminal is now centered at 572.
    click(572, 743)
    time.sleep(.4)
    before = trace().count('(:HARBOR-STATE')
    guest_input.type_text('(with-open-file (s "/dev/console" :direction :output :if-exists :append) (write (list :harbor-state (darterfly/kit::review-state) :errors darterfly/bsd:*background-errors*) :stream s :pretty nil) (terpri s))', True)
    until = time.monotonic() + 8
    while trace().count('(:HARBOR-STATE') <= before and time.monotonic() < until:
        time.sleep(.1)
    time.sleep(.4)
    result = [line for line in trace().splitlines() if line.startswith('(:HARBOR-STATE')][-1]
    assert ':ERRORS NIL)' in result, result
    click(990, 113)
    return result


def run():
    key('esc')
    click(606, 743)
    wait_pixel(800, 300, PAPER, 'Terminal ready for the native review harness')
    time.sleep(.6)
    guest_input.type_text('(load "/usr/src/darterfly/tools/harbor/control-review.lisp")', True)
    until = time.monotonic() + 10
    while not events() and time.monotonic() < until:
        time.sleep(.1)
    expect('review window ready', text='"Darterfly"', choice=':OCEAN', checked='T', slider=50)
    capture('controls-ready')

    click(540, 317)
    key('down')
    wait_pixel(420, 400, (211, 212, 210), 'fast Down keeps the opening menu visible and selects Forest')
    capture('controls-popup-keyboard-candidate')
    count = len(events())
    key('esc')
    unchanged('Escape cancels a candidate without committing it', count)
    key('down')  # Opens the focused closed chooser.
    key('home'); key('down'); key('ret')
    expect('Down skips the unavailable choice and commits Forest', choice=':FOREST')
    key('spc'); key('s'); key('ret')
    expect('dropdown typeahead commits Slate', choice=':SLATE')
    key('spc'); key('tab')
    key('esc')

    click(500, 247); key('ctrl-a'); key('backspace'); key('ret')
    capture('controls-validation-error')
    key('ctrl-z'); key('ret')
    expect('undo restores entry after rejected empty submission', text='"Darterfly"')
    key('ctrl-a')
    text = 'abcdefghijklmnopqrstuvwxyz' * 3
    guest_input.type_text(text)
    capture('controls-long-entry')
    key('home'); key('shift-end')
    capture('controls-long-selection')
    key('ctrl-c'); key('backspace'); key('ctrl-v'); key('ret')
    expect('long-field selection, scrolling and paste preserve exact text', text='"' + text + '"')
    key('ctrl-a'); guest_input.type_text('Darterfly'); key('ret')

    count = len(events())
    move(500, 373); button(True); move(950, 390); button(False)
    unchanged('checkbox release outside its label cancels', count)
    click(500, 373)
    expect('checkbox label is the click target', checked='NIL')
    key('spc')
    expect('Space toggles the focused checkbox on release', checked='T')

    move(552, 419); button(True); move(1100, 419)
    expect('slider clamps outside its right edge', slider=100)
    key('esc'); button(False)
    expect('Escape restores the slider drag origin', slider=50)
    click(550, 419); key('home')
    expect('Home reaches the minimum', slider=0)
    key('end'); key('shift-left')
    expect('End and Shift-arrow obey the slider step', slider=90)
    capture('controls-slider-focus')

    click(283, 469)
    expect('controls disable together', enabled='NIL')
    capture('controls-disabled')
    count = len(events())
    click(331, 547); key('ret'); click(500, 373); click(540, 317)
    unchanged('disabled pointer and keyboard targets cannot act', count)
    click(283, 469)
    expect('controls re-enable', enabled='T')

    count = len(events())
    move(331, 547); button(True)
    capture('controls-command-pointer-pressed')
    move(950, 600); button(False)
    unchanged('command release outside cancels', count)
    move(331, 547); button(True); key('esc'); button(False)
    unchanged('Escape cancels a pointer press released inside', count)
    key('tab'); key('shift-tab')  # Restore visible keyboard focus on Secondary.
    hold('spc', True)
    capture('controls-command-keyboard-pressed')
    unchanged('held Space has not executed', count)
    key('esc'); hold('spc', False)
    unchanged('Escape cancels a held Space', count)
    hold('spc', True); key('tab'); hold('spc', False)
    unchanged('Tab cancels a held Space rather than executing the next control', count)
    key('shift-tab'); key('spc')
    expect('one keyboard release executes exactly once', actions=1)
    move(331, 547); capture('controls-command-hover')

    # A menu taller than the space under its trigger must fit the work area.
    click(900, 317)
    capture('controls-long-menu')
    move(900, 500)
    for _ in range(20):
        qmp('input-send-event', {'events': [
            {'type': 'btn', 'data': {'button': 'wheel-down', 'down': True}},
            {'type': 'btn', 'data': {'button': 'wheel-down', 'down': False}}]})
        time.sleep(.03)
    capture('controls-long-menu-wheel')
    # Last visible row (40th item) after the wheel reaches the bottom.
    click(880, 746)
    expect('wheel reaches and selects the final item', long=39)
    click(900, 317); key('home'); key('ret')
    expect('Home returns a long menu to its first item', long=0)
    for _ in range(20):
        click(540, 317); key('esc')
    print('PASS: 20 popup open/cancel cycles remain responsive', flush=True)

    # Each edge grows outward, then Escape restores the exact original geometry.
    for index, (x, y, dx, dy) in enumerate([(242,370,-90,0),(1038,370,90,0),(640,102,0,-50),(640,648,0,60),
                          (242,102,-90,-50),(1038,102,90,-50),(242,648,-90,60),(1038,648,90,60)]):
        move(x,y); button(True); move(x+dx,y+dy)
        capture('controls-resize-' + str(index + 1))
        key('esc'); button(False)
    capture('controls-resize-restored')
    result = query()
    assert ':FRAME (240 100 800 550)' in result, result
    print('PASS: eight-edge resize/cancel preserves exact geometry and guest error list is empty', flush=True)
    capture('controls-final')
    print('PASS: native control stress complete', flush=True)

if __name__ == '__main__':
    run()
