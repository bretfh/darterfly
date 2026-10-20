#!/usr/bin/env python3
"""Type an ASCII Lisp expression into the focused guest Terminal, without SSH."""
import sys
import time
from vm import qmp

KEYS = {' ': 'spc', '(': 'shift-9', ')': 'shift-0', ':': 'shift-semicolon',
        ';': 'semicolon', '*': 'shift-8', '/': 'slash', '-': 'minus',
        '_': 'shift-minus', '.': 'dot', ',': 'comma', '"': 'shift-apostrophe',
        "'": 'apostrophe', '#': 'shift-3', '+': 'shift-equal', '=': 'equal',
        '>': 'shift-dot', '<': 'shift-comma', '\\': 'backslash', '!': 'shift-1',
        '?': 'shift-slash', '~': 'shift-grave_accent', '%': 'shift-5',
        '[': 'bracket_left', ']': 'bracket_right', '&': 'shift-7'}

def type_text(text, submit=False):
    sequence = []
    for char in text:
        if char in KEYS:
            sequence.append(KEYS[char])
        elif char.isascii() and char.isalnum():
            sequence.append('shift-' + char.lower() if char.isupper() else char)
        else:
            raise ValueError(f'No guest key mapping for {char!r}')
    for name in sequence + (['ret'] if submit else []):
        result = qmp('human-monitor-command', {'command-line': 'sendkey ' + name + ' 1'})
        if result:
            raise RuntimeError(result)
        time.sleep(.025)

if __name__ == '__main__':
    type_text(sys.argv[1], submit=True)
