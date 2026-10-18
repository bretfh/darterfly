"""Tests for evidence integrity and failure reporting in the release driver."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import os
import sys
import tarfile

spec = importlib.util.spec_from_file_location('release', Path(__file__).resolve().parents[1] / 'tools/release.py')
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class EvidenceTests(unittest.TestCase):
    def test_summary_keeps_errors_missing_values_and_tail(self):
        samples = [[{'name': 'latency', 'unit': 'ms', 'value': x}] for x in [1, 2, 3, 4, 100, 'timeout', None]]
        samples.append([])
        metric = release.summarize(samples)['latency']
        self.assertEqual(metric['count'], 5)
        self.assertEqual(metric['median'], 3)
        self.assertEqual(metric['p95'], 100)
        self.assertEqual(metric['max'], 100)
        self.assertEqual(metric['unavailable'], ['timeout', None])
        self.assertEqual(metric['missing'], 1)

    def test_summary_rejects_mixed_units_and_duplicates(self):
        a = {'name': 'latency', 'unit': 'ms', 'value': 1}
        b = dict(a, unit='us')
        with self.assertRaises(ValueError):
            release.summarize([[a], [b]])
        with self.assertRaises(ValueError):
            release.summarize([[a, a]])

    def test_snapshot_is_stable_and_includes_uncommitted_source(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / 'repo'
            root.mkdir()
            (root / 'new.lisp').write_text('(print :new)\n')
            (root / 'run.sh').write_text('#!/bin/sh\n')
            (root / 'run.sh').chmod(0o744)  # Executability is normalized, not mistaken for a concurrent edit.
            hashes = []
            for n in range(2):
                archive = Path(tmp) / f'{n}.tar'
                work = Path(tmp) / f'work{n}'
                work.mkdir()
                with patch.object(release, 'ROOT', root), patch.object(release, 'git', return_value=b'run.sh\0new.lisp\0deleted.lisp\0'):
                    release.snapshot(work, archive, 1234)
                hashes.append(release.sha256(archive))
                with tarfile.open(archive) as tar:
                    self.assertEqual(tar.getnames(), ['new.lisp', 'run.sh'])
                    self.assertEqual(tar.getmember('run.sh').mode, 0o755)
                    self.assertEqual(tar.getmember('new.lisp').mtime, 1234)
            self.assertEqual(hashes[0], hashes[1])

    def test_failed_command_retains_output_and_nonzero_status(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp)
            record = release.execute([sys.executable, '-c', 'print("failure evidence"); raise SystemExit(7)'],
                                     path / 'failure.log', path, os.environ.copy(), 5)
            self.assertEqual(record['status'], 'failed')
            self.assertEqual(record['exit_code'], 7)
            self.assertIn('failure evidence', (path / 'failure.log').read_text())

    def test_timeout_is_not_a_pass(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp)
            record = release.execute([sys.executable, '-c', 'import time; time.sleep(10)'],
                                     path / 'timeout.log', path, os.environ.copy(), .05)
            self.assertEqual(record['status'], 'timeout')
            self.assertEqual(record['exit_code'], 124)

    def test_json_replaces_previous_record(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'manifest.json'
            release.write_json(path, {'status': 'running'})
            release.write_json(path, {'status': 'failed'})
            self.assertEqual(json.loads(path.read_text())['status'], 'failed')
            self.assertFalse(path.with_suffix('.json.tmp').exists())


if __name__ == '__main__':
    unittest.main()
