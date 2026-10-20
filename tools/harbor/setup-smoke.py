#!/usr/bin/env python3
"""Keyboard/persistence regression on the actual Setup app in a fresh live VM.
Changes only the live session's temporary preferences; never installs or erases.
"""
import importlib.util
import time
from pathlib import Path
from smoke import click, key, shot, wait_pixel, PAPER
from vm import BASE

spec = importlib.util.spec_from_file_location('guest_input', Path(__file__).with_name('guest-input.py'))
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


def serial():
    return (BASE/'serial.log').read_text(errors='replace')


def preferences(page, restore=True):
    click(606,743); time.sleep(.4)
    count = serial().count('(:HARBOR-SETUP')
    m.type_text('(with-open-file (s "/dev/console" :direction :output :if-exists :append) (write (list :harbor-setup (darterfly/apps::read-desktop-preferences) :errors darterfly/bsd:*background-errors*) :stream s :pretty nil) (terpri s))', True)
    until = time.monotonic()+8
    while serial().count('(:HARBOR-SETUP') <= count and time.monotonic()<until:
        time.sleep(.1)
    result = [line for line in serial().splitlines() if line.startswith('(:HARBOR-SETUP')][-1]
    for expected in (f':PAGE {page}', ':COLOR :OCEAN', ':CLOCK-24 NIL', ':COMPLETE NIL', ':ERRORS NIL'):
        assert expected in result, result
    if restore:
        click(900,223); time.sleep(.3)
    return result


def run():
    key('esc');click(606,743)
    wait_pixel(800,300,PAPER,'Terminal ready')
    time.sleep(.6)
    m.type_text('(darterfly/apps::launch-app "Setup")',True)
    time.sleep(.7)
    key('tab');key('spc');key('home');key('down');key('ret')
    # Focus must stay on the rebuilt dropdown; this Space opens it again.
    key('spc');key('home');key('ret')
    preferences(0)
    print('PASS: Setup dropdown preserves focus through two saved choices',flush=True)
    key('tab');key('tab');key('ret');time.sleep(.3)
    key('tab')
    for _ in range(4):key('spc')
    preferences(1)
    time.sleep(.4);shot('setup-clock-focus-fixed')
    print('PASS: four Space toggles stay on the clock checkbox and save the expected value',flush=True)
    key('tab');key('tab');key('tab');key('ret')
    preferences(2)
    print('PASS: explicit keyboard Continue advances to the final page',flush=True)
    key('shift-tab');key('ret');key('shift-tab');key('ret')
    preferences(0)
    print('PASS: keyboard Back returns through both prior pages',flush=True)
    key('shift-tab');key('ret');time.sleep(.4)
    preferences(0,restore=False)
    m.type_text('(darterfly/apps::launch-app "Setup")',True)
    time.sleep(.7);shot('setup-reopened')
    print('PASS: Set Up Later and reopen preserve choices without completing setup; no guest background errors',flush=True)

if __name__=='__main__':run()
