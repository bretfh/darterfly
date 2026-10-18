#!/usr/bin/env python3
"""Cross-seed upstream LLD using the native Clang port's shared configuration."""
import importlib.util
from pathlib import Path
import sys

spec = importlib.util.spec_from_file_location(
    'native_clang', Path(__file__).with_name('build-native-clang.py'))
clang = importlib.util.module_from_spec(spec)
spec.loader.exec_module(clang)
if __name__ == '__main__':
    clang.main(['--lld', *sys.argv[1:]])
