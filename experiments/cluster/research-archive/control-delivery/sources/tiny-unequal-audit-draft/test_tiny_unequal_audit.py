"""Prospective invented-fixture tests; no candidate/model/process access."""
import copy
import json
from pathlib import Path
import socket
import struct
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import sys
sys.dont_write_bytecode = True

from tiny12_expected import canonical, expected, sha
from tiny12_fixture import records, suffix
from tiny_unequal_audit import MAXIMUM_BYTES, parse, validate_file, validate_records, validate_suffix


class TinyUnequalAuditTests(unittest.TestCase):
    def setUp(self):
        self.rows = records()
        self.checkpoint, self.wrapper = self.rows[-2:]
        self.report = self.wrapper['comparison']
        self.baseline = self.checkpoint['baseline']
        self.comparison = self.report['comparison']

    def rejects(self, message):
        with self.assertRaisesRegex(ValueError, message):
            validate_records(self.rows)

    def test_prospective_complete_synthetic_file(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'invented-stdout.jsonl'
            raw = b'\n'.join(canonical(row) for row in self.rows) + b'\n'
            path.write_bytes(raw)
            with patch.object(subprocess, 'Popen', side_effect=AssertionError('No process permitted')), \
                 patch.object(socket, 'socket', side_effect=AssertionError('No socket permitted')):
                result = validate_file(path)
            self.assertTrue(result['passed'])
            self.assertEqual(result['nativeStdoutSHA256'], sha(raw))
            self.assertEqual(result['unchangedLegacyRecordCount'], 11)
            self.assertEqual(result['unequal']['inventory']['canonicalTensors'], 352)
            self.assertEqual(result['unequal']['independentlyVerifiedRawLogitRows'], 8)
            self.assertEqual(result['unequal']['stateEntriesPerFrame'], 27)

    def test_legacy_prefix_failure_is_preserved(self):
        self.rows[0]['tensorChecks'] = 236
        self.rejects('Complete tensor ownership')

    def test_exact_record_count(self):
        for rows in (self.rows[:-1], self.rows + [self.rows[-1]], self.rows[:11]):
            with self.subTest(count=len(rows)), self.assertRaisesRegex(ValueError, 'thirteen'):
                validate_records(rows)

    def test_swapped_trailing_records(self):
        self.rows[-2:] = self.rows[-2:][::-1]
        self.rejects('Unequal wrapper fields')

    def test_closed_nested_shapes(self):
        for target in (self.wrapper, self.checkpoint, self.report, self.baseline, self.comparison,
                       self.baseline['request'], self.baseline['frames'][0], self.report['stageLoads'][0]):
            target['unexpected'] = 1
            self.rejects('fields differ')
            del target['unexpected']

    def test_wrong_selection_profile_or_scope(self):
        for field, value in [('selectedCut', 8), ('layerCounts', [8,4]),
                             ('fixtureProfile', 'tiny'), ('throughputMeasurementValid', True)]:
            old = self.wrapper[field]; self.wrapper[field] = value
            self.rejects('wrapper scope/selection')
            self.wrapper[field] = old

    def test_no_optional_null_on_intermediate_frame(self):
        self.baseline['frames'][0]['logits'] = None
        self.rejects('scalar/null')

    def test_integer_lexeme_drift(self):
        for value in (4.0, True, -0.0):
            self.wrapper['selectedCut'] = value
            self.rejects('scalar/null|Boolean substituted')

    def test_false_storage_schema_is_not_integer_one(self):
        self.report['stageLoads'][0]['storageCommitment']['schemaVersion'] = True
        self.rejects('Boolean substituted')

    def test_native_int_overflow(self):
        self.report['memory'][0]['activeMLXBytes'] = 2**63
        self.rejects('native DTO range')

    def test_source_and_plan_pins(self):
        for field in ('sourceConfigurationSHA256', 'planSHA256', 'sourceParameterLayoutSHA256'):
            old = self.baseline['source'][field]
            self.baseline['source'][field] = self.comparison['source'][field] = '0'*64
            self.rejects('Source-derived tiny12 identity')
            self.baseline['source'][field] = self.comparison['source'][field] = old

    def test_stage_construction_and_plan_pins(self):
        for field in ('constructionConfigurationSHA256', 'stagePlanSHA256'):
            old = self.report['stageLoads'][1][field]
            self.report['stageLoads'][1][field] = '0'*64
            self.rejects('Source-derived tiny12 stage metadata')
            self.report['stageLoads'][1][field] = old

    def test_wrong_local_layer_mapping(self):
        tensor = next(t for t in self.report['stageLoads'][1]['activeTensors'] if '.layers.4.' in t['sourceName'])
        tensor['localName'] = tensor['localName'].replace('.layers.0.', '.layers.4.')
        self.rejects('stage metadata differs: activeTensors')

    def test_shape_with_equal_byte_count(self):
        tensor = next(t for t in self.report['stageLoads'][0]['activeTensors'] if t['sourceName'].endswith('conv1d.weight'))
        tensor['shape'] = [4,768,1]
        self.rejects('stage metadata differs: activeTensors')

    def test_f16_source_metadata_policy(self):
        tensor = next(t for t in self.report['stageLoads'][1]['activeTensors'] if t['sourceDType'] == 'float16')
        tensor['sourceDType'] = 'bfloat16'
        self.rejects('stage metadata differs: activeTensors')

    def test_storage_digest(self):
        self.report['stageLoads'][0]['storageCommitmentSHA256'] = '0'*64
        self.rejects('Common commitment SHA')

    def test_wrong_teacher_or_prompt(self):
        for key in ('promptTokenIDs', 'teacherTokenIDs'):
            old = self.baseline['request'][key][0]
            self.baseline['request'][key][0] += 1
            self.rejects('Tiny fixture (prompt|teacher history) differs')
            self.baseline['request'][key][0] = old

    def test_out_of_order_frame(self):
        self.baseline['request']['steps'][3:5] = self.baseline['request']['steps'][3:5][::-1]
        self.rejects('Actual frame/token timeline differs')

    def test_same_request_id_as_old_recording(self):
        self.rows[9]['baseline']['request']['request']['requestID'] = self.baseline['request']['request']['requestID']
        self.rejects('reused one UUID')

    def test_state_geometry_equal_byte_count(self):
        item = next(e for e in self.baseline['frames'][0]['state']['entries'] if e['component'] == 'conv')
        item['shape'] = [1,768,3]
        self.rejects('Independent state component geometry')

    def test_missing_state_owner(self):
        del self.baseline['frames'][0]['state']['entries'][-1]
        self.rejects('State frontier/count')

    def test_changed_candidate_with_fresh_native_digest(self):
        row = self.comparison['frames'][2]['logits']
        row['values'][1] = 7.0
        row['logicalBytesSHA256'] = sha(b''.join(struct.pack('<f', value)[2:] for value in row['values']))
        self.rejects('Baseline/staged native logit bytes differ')

    def test_signed_zero_not_erased(self):
        row = self.comparison['frames'][2]['logits']
        row['values'][0] = 0.0
        self.rejects('Native logit bytes SHA differs')
        self.assertEqual(struct.pack('<f', parse('[-0]')[0]), struct.pack('<f', -0.0))

    def test_nonfinite_or_nonnative_row(self):
        for value in (True, float('inf'), 0.1):
            self.comparison['frames'][2]['logits']['values'][0] = value
            self.rejects('Nonfinite/bool logit|not exactly bfloat16')

    def test_retirement_failure(self):
        self.comparison['allRequestStateRetired'] = False
        self.rejects('Evidence flag differs')

    def test_named_state_cap_unchanged(self):
        self.report['conservativeStateAndBoundaryBytes'] += 1
        self.rejects('Conservative state/boundary estimate')

    def test_strict_raw_json(self):
        for raw in ('{"key":1,"key":2}', '{"key":1,"k\\u0065y":2}', '[1e309]', '[NaN]'):
            with self.subTest(raw=raw), self.assertRaises(ValueError):
                parse(raw)

    def test_bounded_file_and_line_contract(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'invented'
            for data in (b' ' * (MAXIMUM_BYTES+1), b'\n'.join(canonical(x) for x in self.rows) + b'\nextra\n'):
                path.write_bytes(data)
                with self.assertRaisesRegex(ValueError, 'bounded output|stdout line/count'):
                    validate_file(path)

    def test_frozen_legacy_source_pin(self):
        with patch('legacy_prefix.SOURCE_SHA256', '0'*64), self.assertRaisesRegex(ValueError, 'source pin differs'):
            validate_records(self.rows)

    def test_independent_inventory_symbolic_totals(self):
        metadata = expected()
        self.assertEqual(metadata['canonicalTensorCount'], 9*30+3*25+7)
        self.assertEqual(sum(t['sourceDType'] == 'float16' for t in metadata['fullCanonicalTensors']), 9*16+3*14)
        self.assertEqual(sum(t['byteCount'] for t in metadata['fullCanonicalTensors'] if t['sourceDType'] == 'float16'), 190752)
        self.assertEqual([s['loadedTensorBytes'] for s in metadata['stages']], [630648,1224688])


if __name__ == '__main__':
    unittest.main()
