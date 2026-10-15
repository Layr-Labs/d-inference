"""Fabricated CPU evidence only; no27B model/reference/candidate execution."""
import copy
import json
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest
from audit_scope import AuditScope, pinned_scope
from audit_common import agreement, profile, request_context, selected_frame, token_hash
from audit_candidate import compare
from audit_generation import audit
from audit_reference import check_reference
from audit_state import check_state, state_fingerprint
from fabricated import fixture, reference_bytes
from recorded_math import canonical, digest
from derive_profiles import verify
from prepare_expected import expected

BASE = Path(__file__).resolve().parent
REQUEST_ID = '20801ced-ca29-4faf-b71a-9ebbe1886a14'


class RegisteredTests(unittest.TestCase):
    def test_catalog_replays_from_retained_configuration_and_actual_metadata(self):
        self.assertEqual(verify()['profiles'], 2)

    @classmethod
    def setUpClass(cls):
        cls.scope = AuditScope('registered_qwen38_27b', 32, 16, 128, 32)
        cls.prompt, cls.context, cls.admitted, cls.report, cls.expected, cls.candidates = fixture(cls.scope, REQUEST_ID)
        cls.raw = reference_bytes(cls.admitted, cls.report)
        cls.reference = check_reference(cls.raw, cls.context)
        cls.plan = json.loads((BASE / 'inputs/recording-metadata.json').read_text())

    def bad_candidate(self, change):
        candidates = copy.deepcopy(self.candidates)
        change(candidates)
        with self.assertRaises(ValueError):
            compare(self.reference, candidates, self.expected, self.context)

    def bad_reference(self, change):
        report = copy.deepcopy(self.report)
        change(report['execution'])
        with self.assertRaises(ValueError):
            check_reference(reference_bytes(self.admitted, report), self.context)

    def request(self):
        return dict(model=self.scope.model_id, artifactSHA256=self.scope.model['artifact'],
            configurationSHA256=self.scope.model['configuration'], manifestSHA256=self.scope.model['manifest'],
            requestID=REQUEST_ID, promptCount=32, chunkSize=16, outputCount=128, stageCut=32,
            stopTokenIDs=[], mtp=False, promptFileSHA256=digest(self.prompt),
            promptTokenIDsSHA256=self.context['prompt_tokens_sha'])

    def test_legacy_result_is_byte_identical_to_frozen_algorithm(self):
        prompt, context, admitted, report, expected, candidates = fixture()
        actual = canonical(compare(check_reference(reference_bytes(admitted, report), context), candidates, expected, context))
        script = ('from fabricated import fixture,reference_bytes;from audit_reference import check_reference;'
                  'from audit_candidate import compare;from recorded_math import canonical;import sys;'
                  'p,c,a,r,e,s=fixture();sys.stdout.buffer.write(canonical(compare(check_reference(reference_bytes(a,r),c),s,e,c)))')
        original = subprocess.run([sys.executable, '-B', '-c', script], cwd=BASE / 'originals',
                                  capture_output=True, timeout=15, check=True)
        self.assertEqual(original.stderr, b'')
        self.assertEqual(actual, original.stdout)

    def test_exact_27b_metadata_profile_and_complete_comparison(self):
        self.assertEqual(profile(self.scope)['fingerprint'], self.plan['generationProfileSHA256'])
        result = compare(self.reference, self.candidates, self.expected, self.context)
        self.assertEqual((result['modelID'], result['stageCut']), ('registered_qwen38_27b', 32))
        self.assertEqual((result['comparedSelectedTokenCount'], result['finalCompletedFrames'],
                          result['finalCommittedTokens']), (128, 129, 159))
        self.assertEqual(self.report['execution']['maximumTokens'], 160)
        self.assertEqual(result['stageStateEntryCounts'], [72, 72])
        self.assertEqual(result['orderedStateEntriesCompared'], 144)
        self.assertEqual(result['logicalStateBytes'], 164_364_352)
        self.assertEqual(result['positionOffsetEntriesReconstructed'], 16)
        self.assertEqual(result['otherStateEntryDigestsCompared'], 128)
        self.assertEqual(result['finalNativeBF16RowBytesCompared'], 496_640)
        for key in ('perTokenLogitComparisonPerformed', 'candidateIntermediateFrontiersIndependentlyVerified',
                    'tokenChainIndependentlyReconstructed', 'otherStateEntryBytesReconstructed',
                    'nativeExecutionBindingVerified', 'physicalTransferQualified', 'performanceQualification',
                    'throughputMeasurementValid', 'externalTTFTMeasured'):
            self.assertIs(result[key], False)

    def test_partial_final_prefill_chunk_and_profile_cap_are_distinct(self):
        scope = AuditScope('registered_qwen38_27b', 33, 16, 128, 32)
        self.assertEqual(selected_frame(0, scope), dict(sequence=2, phase='prefill',
            tokenOffset=32, tokenCount=1, finalPromptChunk=True))
        self.assertEqual((scope.frames, scope.frontier), (130, 160))
        self.assertEqual(profile(scope)['maximumContextTokens'], 8320)
        p, c, a, r, e, candidates = fixture(scope, REQUEST_ID)
        result = compare(check_reference(reference_bytes(a, r), c), candidates, e, c)
        self.assertEqual(result['finalCommittedTokens'], 160)

    def test_short_9b_uses_same_generalized_comparison(self):
        scope = AuditScope('registered_qwen35_9b', 17, 16, 8, 4)
        p, c, a, r, e, candidates = fixture(scope, REQUEST_ID)
        result = compare(check_reference(reference_bytes(a, r), c), candidates, e, c)
        self.assertEqual((result['comparedSelectedTokenCount'], result['finalCompletedFrames'],
                          result['finalCommittedTokens'], result['orderedStateEntriesCompared']), (8, 9, 24, 72))

    def test_wrong_registered_model_cut_and_request_bounds(self):
        for values in [('unknown', 32, 16, 128, 32), ('registered_qwen38_27b', 32, 16, 128, 4),
                       ('registered_qwen38_27b', True, 16, 128, 32),
                       ('registered_qwen38_27b', 8193, 16, 128, 32),
                       ('registered_qwen38_27b', 32, 0, 128, 32),
                       ('registered_qwen38_27b', 32, 513, 128, 32),
                       ('registered_qwen38_27b', 32, 16, 129, 32)]:
            with self.subTest(values=values), self.assertRaises(ValueError):
                AuditScope(*values)

    def test_pinned_request_plan_identity_substitutions(self):
        self.assertEqual(pinned_scope(self.request(), self.plan), self.scope)
        for key, value in [('model', 'registered_qwen35_9b'), ('artifactSHA256', '0'*64),
                           ('configurationSHA256', '0'*64), ('manifestSHA256', '0'*64),
                           ('stopTokenIDs', [1]), ('mtp', True), ('stageCut', 4)]:
            request = self.request(); request[key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                pinned_scope(request, self.plan)
        for key, value in [('planSHA256', '0'*64), ('stagePlanSHA256', ['0'*64]*2),
                           ('constructionConfigurationSHA256', ['0'*64]*2)]:
            plan = copy.deepcopy(self.plan); plan[key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                pinned_scope(self.request(), plan)

    def test_expected_agreement_is_prepared_without_candidate_inputs(self):
        result = expected(canonical(self.request()), canonical(self.plan), self.prompt,
            self.expected['membershipEpoch'], self.expected['storageCommitmentSHA256'],
            self.expected['numericalPolicySHA256'])
        self.assertEqual(result['rankBuildSHA256'], [self.plan['nativeBinarySHA256']] * 2)
        self.assertEqual(result['requestFingerprint'], self.context['fingerprint'])
        for bad in ('', '0'*63, 'G'*64):
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                expected(canonical(self.request()), canonical(self.plan), self.prompt,
                    self.expected['membershipEpoch'], bad, self.expected['numericalPolicySHA256'])

    def test_legacy_source_counts_and_geometry_are_rejected_for_27b(self):
        for key, value in [('sourceModelTensorBytes', 5_038_041_600), ('layerCount', 32),
                           ('sourceParameterLayoutSHA256', '0'*64)]:
            self.bad_reference(lambda e, k=key, v=value: e['source'].__setitem__(k, v))
        self.bad_reference(lambda e: e['sourceLoad'].__setitem__('tensorCount', 927))
        self.bad_candidate(lambda c: c[0]['stateEntries'][0]['shape'].__setitem__(2, 8192))
        self.bad_candidate(lambda c: c[0]['stateEntries'][1]['shape'].__setitem__(1, 32))

    def test_global_rank_coverage_and_rehashed_wrong_position(self):
        self.bad_candidate(lambda c: c[0]['stateEntries'].pop())
        self.bad_candidate(lambda c: c[1]['stateEntries'].__setitem__(0, c[0]['stateEntries'][0]))
        self.bad_candidate(lambda c: c[0].__setitem__('sourceLayerEnd', 4))
        state = copy.deepcopy(self.report['execution']['finalState'])
        entry = next(e for e in state['entries'] if e['component'] == 'kv.position_offsets')
        entry['sha256'] = digest(struct.pack('<i', 160))
        state['fingerprint'] = state_fingerprint(state['entries'], self.scope)
        with self.assertRaises(ValueError):
            check_state(state, self.scope)

    def test_actual_frame_frontier_and_capacity_join(self):
        self.bad_reference(lambda e: e.__setitem__('maximumTokens', 8320))
        self.bad_reference(lambda e: e['tokens'][0]['frame'].__setitem__('sequence', 15))
        for key, value in [('completedFrames', 143), ('committedTokens', 160), ('finishReason', 'eos')]:
            self.bad_candidate(lambda c, k=key, v=value: c[1]['execution'].__setitem__(k, v))
        self.bad_candidate(lambda c: c[1]['finalFrame'].__setitem__('tokenOffset', 159))

    def test_registered_packet_snapshots_and_expected_binary_binding(self):
        expected = copy.deepcopy(self.expected)
        expected['rankBuildSHA256'] = [self.plan['nativeBinarySHA256']] * 2
        candidates = copy.deepcopy(self.candidates)
        for c in candidates:
            c['agreement'] = copy.deepcopy(expected)
            c['execution']['agreementFingerprint'] = agreement(expected, self.context)
        inputs = dict(prompt=self.prompt, reference_stdout=self.raw,
            rank0_evidence=canonical(candidates[0]), rank1_evidence=canonical(candidates[1]),
            registered_request=canonical(self.request()), registered_plan=canonical(self.plan))
        with tempfile.TemporaryDirectory() as folder:
            base = Path(folder); refs = {}
            for role, raw in inputs.items():
                file = base / role; file.write_bytes(raw)
                refs[role] = dict(path=role, sha256=digest(raw))
            packet = dict(schema='private_registered_generation_comparison_packet_v1', request_id=REQUEST_ID,
                          expected_agreement=expected, files=refs)
            raw = canonical(packet); file = base / 'packet'; file.write_bytes(raw)
            result = audit(file, digest(raw))
            self.assertTrue(result['rawInputSnapshotsRechecked'])
            packet['expected_agreement']['rankBuildSHA256'][1] = '0'*64
            raw = canonical(packet); file.write_bytes(raw)
            with self.assertRaises(ValueError):
                audit(file, digest(raw))
