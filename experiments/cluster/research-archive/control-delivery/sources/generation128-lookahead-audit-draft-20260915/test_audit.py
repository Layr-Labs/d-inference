import copy
import json
import math
from pathlib import Path
import struct
import tempfile
import unittest
from audit_common import exact, parse, agreement, request_context
from audit_reference import check_reference
from audit_candidate import compare
from audit_state import check_state, state_fingerprint
from audit_generation import write_result
from recorded_math import canonical, digest, logical_bytes
from snapshot import snapshot
from fabricated import fixture, reference_bytes


class AuditTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.prompt, cls.context, cls.admitted, cls.report, cls.expected, cls.candidates = fixture()
        cls.raw = reference_bytes(cls.admitted, cls.report)
        cls.reference = check_reference(cls.raw, cls.context)

    def candidate_failure(self, change):
        candidates = copy.deepcopy(self.candidates)
        change(candidates)
        with self.assertRaises(ValueError):
            compare(self.reference, candidates, self.expected, self.context)

    def reference_failure(self, change):
        report = copy.deepcopy(self.report)
        change(report['execution'])
        with self.assertRaises(ValueError):
            check_reference(reference_bytes(self.admitted, report), self.context)

    def test_complete_explicit_evidence_limits_and_independent_counts(self):
        result = compare(self.reference, self.candidates, self.expected, self.context)
        self.assertEqual((result['comparedSelectedTokenCount'], result['finalCompletedFrames'],
                          result['finalCommittedTokens']), (128, 143, 8319))
        self.assertEqual(result['stageStateEntryCounts'], [9, 63])
        self.assertEqual(result['logicalStateBytes'], 324108320)
        self.assertEqual(result['finalNativeBF16RowBytesCompared'], 496640)
        self.assertEqual(result['finalCPUArgmaxTieCount'], 2)
        for key in ('perTokenLogitComparisonPerformed', 'candidateIntermediateFrontiersIndependentlyVerified',
                    'tokenChainIndependentlyReconstructed', 'otherStateEntryBytesReconstructed',
                    'nativeExecutionBindingVerified', 'physicalTransferQualified', 'performanceQualification'):
            self.assertIs(result[key], False)

    def test_each_rank_selected_history_and_final_frontier(self):
        for rank in (0, 1):
            for key, value in [('selectedTokenIDs', [0]*128), ('committedTokens', 8320),
                               ('completedFrames', 144), ('finishReason', 'eos'), ('bothRequestStatesRetired', False)]:
                with self.subTest(rank=rank, key=key):
                    self.candidate_failure(lambda c, r=rank, k=key, v=value: c[r]['execution'].__setitem__(k, v))

    def test_cross_rank_chain_and_exact_expected_agreement(self):
        self.candidate_failure(lambda c: c[1]['execution'].__setitem__('tokenChainSHA256', 'f'*64))
        for key in ('membershipEpoch', 'storageCommitmentSHA256', 'numericalPolicySHA256'):
            self.candidate_failure(lambda c, k=key: c[0]['agreement'].__setitem__(k, 'f'*64))
        self.candidate_failure(lambda c: c[0]['execution'].__setitem__('agreementFingerprint', '0'*64))

    def test_identity_source_plan_stage_and_rank_substitution(self):
        for key in ('constructionConfigurationSHA256', 'sourceConfigurationSHA256', 'stageFingerprint',
                    'storageCommitmentSHA256', 'planFingerprint', 'requestFingerprint'):
            self.candidate_failure(lambda c, k=key: c[1]['execution']['identity'].__setitem__(k, '0'*64))
        self.candidate_failure(lambda c: c.reverse())
        self.candidate_failure(lambda c: c[0].__setitem__('sourceLayerEnd', 8))

    def test_missing_extra_fields_and_bool_integer_refuse(self):
        self.candidate_failure(lambda c: c[0].__setitem__('finalLogits', None))
        self.candidate_failure(lambda c: c[1].pop('finalLogits'))
        self.candidate_failure(lambda c: c[0]['execution'].__setitem__('prefillSchedule', {}))
        self.candidate_failure(lambda c: c[0].__setitem__('rank', False))
        self.candidate_failure(lambda c: c[1]['captureBudget'].__setitem__('extraHostBytes', True))
        self.candidate_failure(lambda c: c[1]['execution'].__setitem__('bothRequestStatesRetired', 1))

    def test_stage_entry_loss_duplicate_order_and_digest_change(self):
        self.candidate_failure(lambda c: c[0]['stateEntries'].pop())
        self.candidate_failure(lambda c: c[0]['stateEntries'].__setitem__(1, c[0]['stateEntries'][0]))
        self.candidate_failure(lambda c: c[0]['stateEntries'].reverse())
        self.candidate_failure(lambda c: c[1]['stateEntries'][0].__setitem__('sha256', '0'*64))
        self.candidate_failure(lambda c: c[1].__setitem__('stageStateSHA256', '0'*64))

    def test_position_offset_reconstruction_refuses_rehashed_wrong_value(self):
        state = copy.deepcopy(self.report['execution']['finalState'])
        offset = next(e for e in state['entries'] if e['component'] == 'kv.position_offsets')
        offset['sha256'] = digest(struct.pack('<i', 8318))
        state['fingerprint'] = state_fingerprint(state['entries'])
        with self.assertRaises(ValueError):
            check_state(state)

    def test_kv_prefix_geometry_and_logical_total(self):
        self.reference_failure(lambda e: e['finalState']['entries'][6]['shape'].__setitem__(2, 8320))
        self.reference_failure(lambda e: e['finalState'].__setitem__('logicalByteCount', 324108321))

    def test_final_full_row_value_and_hash_replay(self):
        self.candidate_failure(lambda c: c[1]['finalLogits']['values'].__setitem__(100, 3.0))
        self.candidate_failure(lambda c: c[1]['finalLogits'].__setitem__('logicalBytesSHA256', 'f'*64))
        self.candidate_failure(lambda c: c[1]['finalLogits']['values'].pop())
        self.candidate_failure(lambda c: c[1]['finalLogits']['values'].__setitem__(100, 1.001))

    def test_signed_zero_is_preserved_in_swift_integer_spelling(self):
        row = dict(shape=[1, 2], dtype='bfloat16', byteCount=4,
                   logicalBytesSHA256=digest(b'\x00\x80\x00\x00'), values=[-0.0, 0.0])
        raw = canonical(row).replace(b'[-0.0,0.0]', b'[-0,0]')
        parsed = parse(raw)
        self.assertEqual(logical_bytes(parsed, 2, 'bfloat16'), b'\x00\x80\x00\x00')
        parsed['values'][0] = 0.0
        with self.assertRaises(ValueError):
            logical_bytes(parsed, 2, 'bfloat16')

    def test_final_tie_argmax_and_compact_full_row_join(self):
        self.reference_failure(lambda e: e['tokens'][-1].__setitem__('maximumTieCount', 1))
        self.reference_failure(lambda e: e['tokens'][-1].__setitem__('maximumLogit', 7.0))
        self.reference_failure(lambda e: e['tokens'][-1].__setitem__('logitsLogicalBytesSHA256', 'f'*64))

    def test_reference_compact_history_and_retirement_order(self):
        self.reference_failure(lambda e: e['tokens'][0]['frame'].__setitem__('sequence', 16))
        self.reference_failure(lambda e: e['tokens'][64].__setitem__('committedTokens', 8255))
        self.reference_failure(lambda e: e['tokens'][1].__setitem__('tokenID', True))
        self.reference_failure(lambda e: e['timing'].__setitem__('retiredNanoseconds', 2))
        self.reference_failure(lambda e: e.__setitem__('selectedTokenIDsSHA256', 'f'*64))

    def test_json_line_framing_duplicate_nonfinite_and_overflow(self):
        for raw in (self.raw[:-1], self.raw + b'\n', self.raw.replace(b'\n', b'\r'), self.raw.split(b'\n')[0]+b'\n'):
            with self.assertRaises(ValueError):
                check_reference(raw, self.context)
        for raw in (b'{"a":1,"a":2}', b'{"a":NaN}', b'{"a":1e999}'):
            with self.assertRaises(ValueError):
                parse(raw)

    def test_boundaries_nonfinite_boolean_row_and_flags(self):
        for value in (True, float('inf'), 1e99):
            row = dict(shape=[1, 1], dtype='bfloat16', byteCount=2,
                       logicalBytesSHA256='0'*64, values=[value])
            with self.assertRaises(ValueError):
                logical_bytes(row, 1, 'bfloat16')
        self.candidate_failure(lambda c: c[0].__setitem__('minimumObservedActualFreeBytes', 6*1024**3 - 1))
        self.candidate_failure(lambda c: c[0].__setitem__('resourceObservationCount', 0))
        self.candidate_failure(lambda c: c[1].__setitem__('intermediateLogitRowsCompared', True))

    def test_prompt_or_request_substitution_refuses_reference(self):
        for context in (request_context(canonical([8]*8192), self.context['request_id']),
                        request_context(self.prompt, '00000000-0000-4000-8000-000000000001')):
            with self.assertRaises(ValueError):
                check_reference(self.raw, context)

    def test_snapshot_and_exclusive_result_write(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'input'
            path.write_bytes(b'abc')
            first = snapshot(path, 3)
            self.assertEqual(first['sha256'], digest(b'abc'))
            with self.assertRaises(ValueError):
                snapshot(path, 2)
            link = Path(folder) / 'link'
            link.symlink_to(path)
            with self.assertRaises(OSError):
                snapshot(link, 3)
            path.write_bytes(b'abd')
            self.assertNotEqual(snapshot(path, 3), first)
            output = Path(folder) / 'result'
            write_result(output, {'status': 'failed'})
            self.assertEqual(output.stat().st_mode & 0o777, 0o600)
            with self.assertRaises(FileExistsError):
                write_result(output, {'status': 'passed'})


if __name__ == '__main__':
    unittest.main()
