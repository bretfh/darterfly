#!/usr/bin/env python3
"""Exercise native completion using guest input. Fresh 1280x800 live Harbor VM.
Screenshots are review evidence; assertions below are native fixture results,
not a claim that every visual criterion can be decided from pixels.
"""
import importlib.util
import time
from pathlib import Path
from smoke import click, key, shot, move, button
from vm import BASE, qmp
spec = importlib.util.spec_from_file_location('guest', Path(__file__).with_name('guest-input.py'))
guest = importlib.util.module_from_spec(spec); spec.loader.exec_module(guest)
def text(value):
    guest.type_text(value); time.sleep(.55)
def command(query):
    key('alt-x'); time.sleep(.55); text(query); key('ret'); time.sleep(.7)
def choose(query):
    key('meta_l-grave_accent'); time.sleep(.65); text(query); key('ret'); time.sleep(.5)
def wait_serial(marker, timeout=40):
    end=time.monotonic()+timeout
    while time.monotonic()<end:
        if marker in (BASE/'serial.log').read_text(): return
        time.sleep(.25)
    raise AssertionError('Missing guest assertion: '+marker)

time.sleep(8)
click(880,532); time.sleep(1); click(604,736); time.sleep(1)
guest.type_text('(load "/usr/src/darterfly/tools/harbor/completion-review.lisp")', True)
wait_serial("HARBOR-COMPLETION :READY", 60)
time.sleep(1); click(500,130)
key('meta_l-grave_accent'); time.sleep(.8); shot('completion-forty-final')
text('notes editor walks'); shot('completion-identity-final'); key('ret'); time.sleep(.6)
key('ctrl-a'); text('Unsaved edits must survive'); key('shift-left'); key('shift-left')
key('meta_l-m'); time.sleep(.5); choose('notes editor walks'); shot('completion-preservation-final')
command('stress minimize'); wait_serial('HARBOR-STRESS :PASS'); shot('completion-stress-final')
command('fail then retry'); shot('completion-error-final'); click(780,85); time.sleep(.8); shot('completion-retry-final'); key('esc')
command('slow completion'); text('newest'); time.sleep(1.1); shot('completion-slow-final'); key('esc'); time.sleep(1)
command('slow completion'); key('esc'); time.sleep(1.3); shot('completion-cancel-final')
key('alt-x'); time.sleep(.6); text('review'); click(600,248); time.sleep(.6); shot('completion-disabled-pointer-final'); key('esc')
key('alt-x'); time.sleep(.6); text('unavailable'); key('ret'); shot('completion-disabled-final'); key('ctrl-g')
command('record a review'); key('ret'); wait_serial(':ACTIONS 1')
key('meta_l-grave_accent'); time.sleep(.7); key('ctrl-end'); time.sleep(.6); shot('completion-last-page-final'); key('ctrl-home'); key('pgdn'); time.sleep(.6); shot('completion-page-final'); key('esc')
key('meta_l-grave_accent'); time.sleep(.7); text('zzzzzzz'); key('ret'); shot('completion-no-match-final'); key('tab'); key('ret'); time.sleep(.5)
# Repeated popup destruction during active provider work must not steal later focus.
for _ in range(24):
    key('meta_l-grave_accent'); key('esc')
time.sleep(1); shot('completion-dismiss-stress-final')
command('rename during'); time.sleep(2); shot('completion-rename-final'); key('esc')
command('close during'); time.sleep(2); key('ret'); time.sleep(.6); shot('completion-disappeared-final'); key('esc')
print('Native sequence complete. Review screenshots and HARBOR-STRESS in serial.log.')
