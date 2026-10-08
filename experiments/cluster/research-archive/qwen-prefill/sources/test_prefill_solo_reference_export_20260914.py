#!/usr/bin/env python3
"""CPU-only focused tests of the frozen solo descriptor exporter."""
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parent
EXPORTER = ROOT / 'export_prefill_solo_reference_20260914.py'
if hashlib.sha256(EXPORTER.read_bytes()).hexdigest() != 'd5571a1c3ccb3071e2c271fedd76b938eaae3096e88872da80790c68fd1514fc':
    raise ValueError('Frozen exporter differs')
spec = importlib.util.spec_from_file_location('frozen_solo_export_tests', EXPORTER)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


class SoloReferenceExportTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        m.verify_pins()
        cls.helper = m.load_helper()
        cls.data = m.OUTPUT.read_bytes()
        if m.sha(cls.data) != '782138cb276748af1b4a8d9f2d5d76461ae9973a5919e4f4317035c551b2976b':
            raise ValueError('Frozen descriptor differs')
        cls.descriptor = json.loads(cls.data)
        cls.rows, _ = cls.helper.read_rows(m.CURRENT)
        cls.expected = json.loads(m.EXPECTED.read_text())
        cls.summary = json.loads(m.COMPARISON.read_text())['comparison']

    def validate(self, data):
        return m.validate_descriptor_bytes(data, self.descriptor, self.helper)

    def changed(self, mutate):
        value = copy.deepcopy(self.descriptor)
        mutate(value)
        return m.canonical(value)

    def test_valid_closed_integer_descriptor(self):
        self.assertEqual(self.validate(self.data), self.descriptor)
        self.assertNotIn('values', self.descriptor['finalLogits'])

    def test_fractional_integer_lexeme_rejected(self):
        with self.assertRaises(ValueError):
            self.validate(self.data.replace(b'"schemaVersion":1', b'"schemaVersion":1.0'))

    def test_exponent_integer_lexeme_rejected(self):
        with self.assertRaises(ValueError):
            self.validate(self.data.replace(b'"schemaVersion":1', b'"schemaVersion":1e0'))

    def test_escaped_nested_duplicate_rejected(self):
        with self.assertRaisesRegex(ValueError, 'Duplicate'):
            self.validate(self.data.replace(b'"layerCount":32', b'"layerCount":32,"layer\\u0043ount":32'))

    def test_unknown_nested_raw_values_rejected(self):
        with self.assertRaises(ValueError):
            self.validate(self.changed(lambda d: d['finalLogits'].update(values=[0])))

    def test_boolean_count_rejected(self):
        with self.assertRaises(ValueError):
            self.validate(self.changed(lambda d: d['request'].update(outputCount=True)))

    def test_incomplete_state_rejected(self):
        with self.assertRaises(ValueError):
            self.validate(self.changed(lambda d: d['finalState']['entries'].pop()))

    def test_wrong_baseline_request_rejected(self):
        with self.assertRaises(ValueError):
            self.validate(self.changed(lambda d: d['request'].update(baselineRequestFingerprint='0' * 64)))

    def test_wrong_selected_token_rejected(self):
        with self.assertRaises(ValueError):
            self.validate(self.changed(lambda d: d['selection'].update(tokenID=2527)))

    def test_oversized_descriptor_rejected(self):
        with self.assertRaises(ValueError):
            self.validate(self.data + b' ' * m.MAX_DESCRIPTOR_BYTES)

    def test_changed_fixed_input_rejected(self):
        with tempfile.TemporaryDirectory(prefix='solo-export-cpu-fixture-') as directory:
            root = Path(directory)
            (root / 'changed.json').write_bytes(b'changed')
            with patch.object(m, 'ROOT', root), patch.object(m, 'PINS', {'changed.json': m.sha(b'original')}):
                with self.assertRaisesRegex(ValueError, 'Frozen input differs'):
                    m.verify_pins()

    def test_derivation_uses_baseline_and_not_candidate_fields(self):
        rows = [self.rows[0], {'inventedCandidateValues': [123]}]
        descriptor, data, summary = m.derive_descriptor(self.helper, rows, self.expected, self.summary)
        self.assertEqual(data, self.data)
        self.assertEqual(descriptor, self.descriptor)
        self.assertEqual(summary['reconstructedCandidateRows'], 0)

    def test_changed_baseline_values_rejected_before_export(self):
        rows = copy.deepcopy(self.rows)
        rows[0]['baseline']['frames'][-1]['logits']['values'][0] = 0.125
        with self.assertRaises(ValueError):
            m.derive_descriptor(self.helper, rows, self.expected, self.summary)

    def test_existing_output_preserved(self):
        with tempfile.TemporaryDirectory(prefix='solo-export-cpu-fixture-') as directory:
            target = Path(directory) / 'existing.json'
            target.write_bytes(b'preserve')
            with patch.object(m, 'OUTPUT', target), patch.object(m.sys, 'argv', ['fake']), \
                 patch.object(m, 'prepare', side_effect=AssertionError('Derivation forbidden')):
                with self.assertRaisesRegex(ValueError, 'Preserve existing'):
                    m.main()
            self.assertEqual(target.read_bytes(), b'preserve')

    def test_input_override_rejected_before_derivation(self):
        with patch.object(m.sys, 'argv', ['fake', '--input', 'other']), \
             patch.object(m, 'prepare', side_effect=AssertionError('Derivation forbidden')):
            with self.assertRaisesRegex(ValueError, 'No input overrides'):
                m.main()


if __name__ == '__main__':
    unittest.main(verbosity=2)
