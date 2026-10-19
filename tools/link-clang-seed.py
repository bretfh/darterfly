#!/usr/bin/env python3
"""Resolve upstream archives/COMDAT on the host, leaving libsa for Lisp's linker.

This cross-seeding step produces ET_REL, never a Linux executable. The final
ELF is linked with Darterfly's ordinary link-native-program and shared libsa.
"""
import json
from pathlib import Path
import shutil
import subprocess
import sys

args = sys.argv[1:]
output = args[args.index('-o') + 1]
inputs = [a for a in args[:args.index('-o')] if a.endswith(('.o', '.a'))]
# CMake's detected POSIX libraries describe APIs supplied by shared libsa.
# Reject everything else rather than accidentally importing a host library.
for arg in args:
    if arg.startswith('-l') and arg not in ('-lm', '-lpthread', '-lpthreads', '-lrt', '-ldl'):
        raise SystemExit('Unexpected library: ' + arg)
subprocess.run([shutil.which('ld.lld'), '-r', '--gc-sections', '-u', 'main',
                '--start-group', *inputs, '--end-group', '-o', output], check=True)
Path(output + '.inputs.json').write_text(json.dumps(inputs, indent=2) + '\n')
