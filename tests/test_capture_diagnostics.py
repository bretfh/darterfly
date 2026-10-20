import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("capture", Path(__file__).resolve().parents[1] / "tools/capture-diagnostics.py")
capture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(capture)


class CaptureTests(unittest.TestCase):
    def test_gap_then_recovery_is_retained_and_key_is_redacted(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "capture.jsonl"
            replies = [TimeoutError("target did not answer"),
                       {"status": ["done"], "value": 'boot=2 secret="key"'}]
            with patch.object(capture, "sample", side_effect=replies), patch.object(capture.time, "sleep"):
                capture.capture("test", 4011, '"key"', output, 2, .1, .1)
            rows = [json.loads(line) for line in output.read_text().splitlines()]
            self.assertIn("error", rows[0])
            self.assertEqual(rows[1]["reply"]["value"], "boot=2 secret=[redacted]")
            self.assertEqual(output.stat().st_mode & 0o777, 0o600)
            with self.assertRaises(FileExistsError):
                capture.capture("test", 4011, "key", output, 1, .1, .1)

    def test_reply_size_and_truncation_are_rejected(self):
        with self.assertRaises(ValueError):
            capture.Reader(io.BytesIO(b"2000000:")).read()
        with self.assertRaises(EOFError):
            capture.Reader(io.BytesIO(b"5:ab")).read()
        self.assertEqual(capture.Reader(io.BytesIO(b"d6:statusl4:doneee")).read(),
                         {"status": ["done"]})


if __name__ == "__main__":
    unittest.main()
