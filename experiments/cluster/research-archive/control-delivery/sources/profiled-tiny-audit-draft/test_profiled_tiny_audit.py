"""Prospective oracle rejection tests; invented records only, no candidate read."""
import copy
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from profiled_tiny_audit_fixture import records
from profiled_tiny_expected import canonical, configuration, native_logit_bytes, sha
from qwen_profiled_tiny_audit import read_records, validate, validate_rows


class Tests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / 'invented.jsonl'
        for name in ('subprocess.run', 'subprocess.Popen', 'socket.socket', 'os.killpg'):
            guard = patch(name, side_effect=AssertionError('Process/socket/signal forbidden'))
            guard.start(); self.addCleanup(guard.stop)

    def rejects(self, mutate):
        rows = records(); mutate(rows)
        with self.assertRaises((ValueError, KeyError, TypeError, OverflowError)): validate_rows(rows)

    def test_complete_fixed_cpu_fixture(self):
        self.path.write_text(''.join(json.dumps(row) + '\n' for row in records()))
        result = validate(self.path)
        self.assertEqual(result['parityFrames'], 38); self.assertEqual(result['fullLogitRows'], 4)
        self.assertEqual([row['frames'] for row in result['fixtures']], [3, 16, 3, 16])
        self.assertEqual(result['contextTokens'], 8193)
        self.assertFalse(result['throughputQualified'])

    def test_unknown_profile_or_unpinned_environment(self):
        for mutate in (lambda x: x[0].update(profile='legacy'),
                       lambda x: x[0]['arithmeticEnvironment']['requiredValues'].update(MLX_ENABLE_TF32='0'),
                       lambda x: x[0]['arithmeticEnvironment'].update(requiredAbsentNames=[])):
            self.rejects(mutate)

    def test_config_context_or_profile_mutation_rejects_even_with_consistent_native_ids(self):
        def mutate(rows):
            bad = configuration('float32'); bad['max_position_embeddings'] = 8192
            digest = sha(canonical(bad))
            for receipt in rows[1]['receipts']: receipt['sourceConfigurationSHA256'] = digest
            rows[3]['sourceConfigurationSHA256'] = digest; rows[4]['sourceConfigurationSHA256'] = digest
        self.rejects(mutate)

    def test_loader_count_shape_bytes_or_source_overlap_rejected(self):
        for mutate in (lambda x: x[1].update(tensorChecks=236),
                       lambda x: x[1]['receipts'][0]['activeTensors'][0].update(byteCount=8),
                       lambda x: x[1]['receipts'][1]['activeTensors'][0].update(sourceName='cpu.fixture.0.0'),
                       lambda x: x[1].update(sourceFilesCorruptedAndDeleted=False)):
            self.rejects(mutate)

    def test_missing_or_reordered_record_and_wrong_retirement_reject(self):
        for mutate in (lambda x: x.pop(), lambda x: x.__setitem__(slice(2, 4), x[2:4][::-1]),
                       lambda x: x[2].update(failedStageFrontiers=[512, 512]),
                       lambda x: x[2].update(bothRequestsFailedAndRetired=False)):
            self.rejects(mutate)

    def test_prompt_step_and_fingerprint_changes_reject(self):
        for mutate in (lambda x: x[3]['request']['promptTokenIDs'].__setitem__(0, 99),
                       lambda x: x[3]['request']['steps'][1]['frame'].update(tokenOffset=511),
                       lambda x: x[3]['request'].update(fingerprint='f' * 64),
                       lambda x: x[3]['request'].update(teacherTokenIDs=[17]),
                       lambda x: x[3]['request']['request'].update(promptCount=1025.0)):
            self.rejects(mutate)

    def test_reused_request_uuid_rejected(self):
        self.rejects(lambda x: x[3]['request']['request'].update(requestID=x[2]['request']['requestID']))

    def test_state_component_count_bytes_or_final_frontier_reject(self):
        for mutate in (lambda x: x[4]['frames'][0].update(stateEntriesCompared=17),
                       lambda x: x[8]['frames'][0].update(stateBytesCompared=1),
                       lambda x: x[4]['frames'][-1].update(committedTokens=8191),
                       lambda x: x[3]['frames'][0].update(logitsBytesExact=True)):
            self.rejects(mutate)

    def test_full_logit_shape_digest_finiteness_or_selected_token_reject(self):
        for mutate in (lambda x: x[3]['frames'][-1]['logits'].update(shape=[1, 1]),
                       lambda x: x[3]['frames'][-1]['logits']['values'].pop(),
                       lambda x: x[3]['frames'][-1]['logits']['values'].__setitem__(0, float('nan')),
                       lambda x: x[3]['frames'][-1]['logits'].update(logicalBytesSHA256='f' * 64),
                       lambda x: x[3].update(stageSelectedToken=18)):
            self.rejects(mutate)

    def test_equal_maxima_choose_lowest_index(self):
        rows = records(); row = rows[3]; logits = row['frames'][-1]['logits']
        logits['values'][29] = logits['values'][17]
        logits['logicalBytesSHA256'] = sha(native_logit_bytes(logits['values'], 'float32'))
        self.assertEqual(validate_rows(rows)['fixtures'][0]['maximumTieCount'], 2)
        row['baselineSelectedToken'] = row['stageSelectedToken'] = 29
        with self.assertRaises(ValueError): validate_rows(rows)

    def test_json_duplicate_blank_partial_nonfinite_and_size_limits(self):
        valid = ''.join(json.dumps(row) + '\n' for row in records())
        for raw in ('{\"kind\":1,\"\\u006bind\":2}\n' + '\n'.join(['{}'] * 8) + '\n',
                    valid.rstrip('\n'), valid + '\n', valid.replace('9.0', 'NaN', 1)):
            self.path.write_text(raw)
            with self.assertRaises(ValueError): read_records(self.path)
        self.path.write_bytes(b'x' * (8 * 1024**2 + 1))
        with self.assertRaises(ValueError): read_records(self.path)


if __name__ == '__main__': unittest.main()
