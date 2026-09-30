#!/usr/bin/env python3
"""Offline routing regression: missing inputs skip, corrupt inputs still fail."""
import contextlib
import io
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import test as host_test
import vendor


class OfflineTest(unittest.TestCase):
    def test_empty_vendor(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(vendor, 'ROOT', Path(directory)):
            with patch('urllib.request.urlopen', side_effect=AssertionError('network forbidden')):
                with patch.object(host_test, 'run', side_effect=AssertionError('generation before preflight')):
                    output = io.StringIO()
                    with contextlib.redirect_stdout(output):
                        host_test.main()
                    self.assertIn('SKIP venus-gen-test', output.getvalue())
                    self.assertIn('make venus-vendor', output.getvalue())
                    self.assertFalse((Path(directory) / 'vendor').exists())

    def test_missing_oracle(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(vendor, 'ROOT', Path(directory)):
            root = Path(directory) / 'vendor'
            for name in ('vk.xml', 'venus-protocol/.git', 'venus-protocol/vkxml.py', 'venus-protocol/vn_protocol.py'):
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.touch()
            self.assertEqual(vendor.missing_test_inputs(), ['venus-python (pinned Mako/MarkupSafe)'])

    def test_invalid_inputs_fail(self):
        with patch.object(host_test, 'missing_test_inputs', return_value=[]):
            with patch.object(host_test, 'check', side_effect=SystemExit('revision mismatch')):
                with self.assertRaisesRegex(SystemExit, 'revision mismatch'):
                    host_test.main()


if __name__ == '__main__':
    unittest.main()
