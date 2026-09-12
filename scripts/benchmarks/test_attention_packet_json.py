"""Malformed JSON metadata must produce a complete refusal report."""

import json
from pathlib import Path
import sys
import tempfile
import unittest

from attention_packet.__main__ import main
from attention_packet.files import PacketError, parse_json
from attention_packet_fixtures import Fixture


class PacketJSONTests(unittest.TestCase):
    def test_finite_json_numbers_preserve_their_values(self):
        self.assertEqual(parse_json(b'{"large":1e308,"small":1e-300,"integer":123}'),
                         {"large": 1e308, "small": 1e-300, "integer": 123})

    def test_overflow_and_nonstandard_constants_are_refused(self):
        for value in (b'1e400', b'-1e400', b'NaN', b'Infinity', b'-Infinity'):
            with self.subTest(value=value), self.assertRaises(PacketError):
                parse_json(b'{"metric":' + value + b'}')
        with self.assertRaisesRegex(PacketError, "duplicate JSON key: field"):
            parse_json(b'{"field":1,"field":2}')

    def test_oversized_integer_conversion_is_a_packet_error(self):
        # NumPy's supported Python runtimes enforce the JSON integer digit cap.
        previous = sys.get_int_max_str_digits()
        try:
            sys.set_int_max_str_digits(4300)
            with self.assertRaisesRegex(PacketError, "invalid bounded packet JSON"):
                parse_json(b'{"metric":' + b'1' * 4301 + b'}')
        finally:
            sys.set_int_max_str_digits(previous)

    def test_overflow_metadata_keeps_a_complete_exclusive_refusal_artifact(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixture = Fixture(root / "packet")
            fixture.document["identity"]["extraMeasurement"] = 1.0
            source = fixture.save()
            source.write_text(source.read_text().replace('"extraMeasurement": 1.0',
                                                        '"extraMeasurement": 1e400'))
            output = root / "analysis.json"
            self.assertEqual(main([str(source), "--output", str(output)]), 2)
            report = json.loads(output.read_text())
            self.assertEqual(report["schema"], "darkbloom.attention-analysis.v1")
            self.assertEqual(report["status"], "refused")
            self.assertIn("nonfinite JSON number", report["error"])
            with self.assertRaises(FileExistsError):
                main([str(source), "--output", str(output)])
