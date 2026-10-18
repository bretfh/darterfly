#!/usr/bin/env python3
"""Cross-seed upstream llvm-ar and both TableGen tools with shared libsa."""
import argparse
import importlib.util
from pathlib import Path

spec = importlib.util.spec_from_file_location(
    'native_clang', Path(__file__).with_name('build-native-clang.py'))
clang = importlib.util.module_from_spec(spec)
spec.loader.exec_module(clang)

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--skip-prerequisites', action='store_true',
                        help='Reuse host generators and the C++ runtime')
    args = parser.parse_args()
    for index, tool in enumerate(('llvm-ar', 'llvm-tblgen', 'clang-tblgen')):
        options = ['--tool', tool]
        if index or args.skip_prerequisites:
            options.append('--skip-prerequisites')
        clang.main(options)
