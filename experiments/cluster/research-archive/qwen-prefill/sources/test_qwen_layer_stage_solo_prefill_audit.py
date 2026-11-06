#!/usr/bin/env python3
"""Prospective synthetic solo output fixtures; no candidate run is read."""
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
import uuid

ROOT = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('solo_output_audit_tests', ROOT / 'qwen_layer_stage_solo_prefill_audit.py')
a = importlib.util.module_from_spec(spec)
spec.loader.exec_module(a)


def fixture():
    exporter, helper, origin, _, _, named_bytes = a.context()
    baseline = helper.read_rows(exporter.CURRENT)[0][0]['baseline']
    request = copy.deepcopy(baseline['request'])
    uid = '11111111-2222-4333-8444-555555555555'
    request['request']['requestID'] = uid.upper()
    simple = a.sha(f'qwen-stage-request-v1|{uid}|65|32|1'.encode())
    request['fingerprint'] = a.sha(('qwen-layer-stage-recorded-request-v1\n' + simple +
        '\nvocabulary=248320\nprompt=' + ','.join(map(str, request['promptTokenIDs'])) + '\nteacher=').encode())
    reference = exporter.OUTPUT.read_bytes()
    pin = a.sha(reference)
    ready = dict(kind='qwen_layer_stage_solo_prefill_ready', schemaVersion=1,
        verifiedModelLoaded=True, freshRequestStateCreated=False, referenceFileSHA256=pin,
        baselineEvidenceFingerprint=origin['baselineEvidenceFingerprint'],
        request=copy.deepcopy(request), source=copy.deepcopy(origin['source']))
    commits = [{key: copy.deepcopy(frame[key]) for key in ('frame', 'committedTokens', 'outputKind', 'outputShape', 'outputDType')}
        for frame in baseline['frames']]
    final = copy.deepcopy(commits[-1]['frame'])
    selection = dict(requestFingerprint=simple, recordedRequestFingerprint=request['fingerprint'],
        frame=final, committedTokens=65, vocabularySize=248320, outputOrdinal=0,
        policy=origin['selection']['policy'], tokenID=origin['selection']['tokenID'],
        logitsShape=[1, 248320], logitsDType='bfloat16', selectionDType='uint32', allLogitsFinite=True)
    timing = dict(startUptimeNanoseconds=1_000_000_000_000, stopUptimeNanoseconds=1_001_000_000_000,
        elapsedNanoseconds=1_000_000_000, promptTokensPerFirstTokenSecond=65.0,
        postStopThroughRequestCloseNanoseconds=10_000_000,
        includesFreshRequestState=True, includesFiniteArgmaxAndScalarReadback=True,
        includesBoundedCommitMetadata=True, includesTransport=False,
        excludesLoadReadinessFinalCaptureAndRetirement=True)
    execution = dict(kind='qwen_layer_stage_solo_prefill_request_result', schemaVersion=1,
        correctnessOnly=True, throughputMeasurementValid=False, matchedChunkSolo=True, physicalTransferQualified=False,
        referenceFileSHA256=pin, baselineEvidenceFingerprint=origin['baselineEvidenceFingerprint'],
        source=copy.deepcopy(origin['source']), request=copy.deepcopy(request), commits=commits, selection=selection,
        referenceSelectedTokenID=origin['selection']['tokenID'], referenceMaximumTieCount=origin['selection']['maximumTieCount'],
        finalLogits=copy.deepcopy(origin['finalLogits']), finalState=copy.deepcopy(origin['finalState']),
        timing=timing, completedFrames=3, committedTokens=65,
        stateMetadataAndDigestsExact=True, logitMetadataAndDigestExact=True, selectedTokenExact=True,
        nativeLogitBytesCompared=False, perFrameStateCaptures=0, perFrameLogitCaptures=0,
        finalStateCaptures=1, finalLogitCaptures=1, nativeTokenSelections=1, allRequestStateRetired=True)
    # Deliberately fabricated observations and clocks: source-derived metadata
    # and the historical baseline do not make these candidate native evidence.
    weights = origin['source']['sourceModelTensorBytes']
    phases = ['before_solo_model_load', 'solo_model_loaded_no_request_state',
        'solo_request_retired_weights_resident', 'solo_model_released_cache_cleared']
    memory = [dict(phase=phase, activeMLXBytes=active, cachedMLXBytes=0,
        peakMLXBytesSinceProcessStart=0 if index == 0 else weights + 100_000_000)
        for index, (phase, active) in enumerate(zip(phases, [0, weights, weights, 2016]))]
    report = dict(kind='qwen_layer_stage_solo_prefill_report', schemaVersion=1,
        completed=True, correctnessOnly=True, throughputMeasurementValid=False, interprocessTransportUsed=False,
        physicalTransferQualified=False, allRequestStateRetired=True, modelReleased=True,
        conservativeStateAndBoundaryBytes=named_bytes, execution=execution, memory=memory)
    return [ready, report], reference, pin


def setpath(rows, path, value):
    item = rows
    for key in path[:-1]:
        item = item[key]
    item[path[-1]] = value


class SoloOutputAuditTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.rows, cls.reference, cls.pin = fixture()

    def check(self, rows=None, reference=None, pin=None):
        return a.validate_reports(rows if rows is not None else self.rows,
            reference if reference is not None else self.reference, pin if pin is not None else self.pin)

    def test_positive_synthetic_contract(self):
        summary = self.check()
        self.assertEqual(summary['completedFrames'], 3)
        self.assertEqual(summary['reconstructedCandidateNativeRows'], 0)
        self.assertFalse(summary['candidateNativeLogitBytesCompared'])
        self.assertFalse(summary['throughputQualified'])

    def test_canonical_staged_reference_bytes_differ_but_content_matches(self):
        # Same transformation class as rank_worker serializing input_files.
        reference = json.dumps(json.loads(self.reference), sort_keys=True).encode()
        pin = a.sha(reference)
        self.assertNotEqual(pin, self.pin)
        rows = copy.deepcopy(self.rows)
        rows[0]['referenceFileSHA256'] = rows[1]['execution']['referenceFileSHA256'] = pin
        self.assertEqual(self.check(rows, reference, pin)['stagedReferenceSHA256'], pin)

    def test_real_file_api_uses_only_synthetic_candidate(self):
        with tempfile.TemporaryDirectory(prefix='solo-oracle-cpu-fixture-') as directory:
            p = Path(directory)
            stdout = p / 'synthetic.jsonl'
            reference = p / 'reference.json'
            stdout.write_bytes(b'\n'.join(json.dumps(x, separators=(',', ':')).encode() for x in self.rows) + b'\n')
            reference.write_bytes(self.reference)
            result = a.validate(stdout, reference, self.pin)
            self.assertTrue(result['frozenInputsUnchanged'])

    def test_wrong_caller_reference_pin_rejected(self):
        with self.assertRaises(ValueError): self.check(pin='0' * 64)

    def test_coherent_changed_reference_rejected_even_with_new_file_pin(self):
        descriptor = json.loads(self.reference)
        descriptor['selection']['tokenID'] += 1
        reference = json.dumps(descriptor).encode()
        pin = a.sha(reference)
        rows = copy.deepcopy(self.rows)
        rows[0]['referenceFileSHA256'] = rows[1]['execution']['referenceFileSHA256'] = pin
        rows[1]['execution']['selection']['tokenID'] = descriptor['selection']['tokenID']
        with self.assertRaises(ValueError): self.check(rows, reference, pin)

    def test_fractional_reference_integer_rejected_before_normalization(self):
        reference = self.reference.replace(b'"schemaVersion":1', b'"schemaVersion":1.0')
        pin = a.sha(reference)
        rows = copy.deepcopy(self.rows)
        rows[0]['referenceFileSHA256'] = rows[1]['execution']['referenceFileSHA256'] = pin
        with self.assertRaises(ValueError): self.check(rows, reference, pin)

    def test_coherent_source_change_rejected(self):
        rows = copy.deepcopy(self.rows)
        rows[0]['source']['artifactAggregateSHA256'] = '0' * 64
        rows[1]['execution']['source']['artifactAggregateSHA256'] = '0' * 64
        with self.assertRaises(ValueError): self.check(rows)

    def test_baseline_uuid_reuse_rejected(self):
        exporter, helper, *_ = a.context()
        request = helper.read_rows(exporter.CURRENT)[0][0]['baseline']['request']
        rows = copy.deepcopy(self.rows)
        rows[0]['request'] = copy.deepcopy(request)
        rows[1]['execution']['request'] = copy.deepcopy(request)
        with self.assertRaises(ValueError): self.check(rows)

    def test_coherent_state_digest_tamper_rejected(self):
        rows = copy.deepcopy(self.rows)
        state = rows[1]['execution']['finalState']
        state['entries'][0]['sha256'] = '0' * 64
        state['fingerprint'] = a.context()[1].state_hash(state['entries'], 65)
        with self.assertRaises(ValueError): self.check(rows)

    def test_unknown_field_rejected(self):
        rows = copy.deepcopy(self.rows)
        rows[1]['execution']['invented'] = 1
        with self.assertRaises(ValueError): self.check(rows)

    def test_duplicate_escaped_json_key_rejected(self):
        raw = b'\n'.join(json.dumps(x, separators=(',', ':')).encode() for x in self.rows)
        raw = raw.replace(b'"schemaVersion":1', b'"schemaVersion":1,"schema\\u0056ersion":1', 1)
        with self.assertRaises(ValueError): a.parse_rows(raw)

    def test_extra_jsonl_record_rejected(self):
        raw = b'\n'.join(json.dumps(x).encode() for x in self.rows) + b'\n{}'
        with self.assertRaises(ValueError): a.parse_rows(raw)

    def test_nonfinite_json_rate_rejected(self):
        rows = copy.deepcopy(self.rows)
        rows[1]['execution']['timing']['promptTokensPerFirstTokenSecond'] = float('nan')
        raw = b'\n'.join(json.dumps(x).encode() for x in rows)
        with self.assertRaises(ValueError): a.parse_rows(raw)

    def test_oversized_stdout_rejected(self):
        with self.assertRaises(ValueError): a.parse_rows(b' ' * (a.MAX_STDOUT_BYTES + 1))


MUTATIONS = {
    'ready_kind': ([0, 'kind'], 'other'),
    'premature_request_state': ([0, 'freshRequestStateCreated'], True),
    'ready_reference_pin': ([0, 'referenceFileSHA256'], '0' * 64),
    'execution_reference_pin': ([1, 'execution', 'referenceFileSHA256'], '0' * 64),
    'baseline_evidence_pin': ([1, 'execution', 'baselineEvidenceFingerprint'], '0' * 64),
    'mismatched_ready_request': ([1, 'execution', 'request', 'request', 'requestID'], str(uuid.UUID(int=3))),
    'changed_prompt': ([0, 'request', 'promptTokenIDs', 0], 42),
    'commit_frontier': ([1, 'execution', 'commits', 1, 'committedTokens'], 63),
    'commit_offset': ([1, 'execution', 'commits', 1, 'frame', 'tokenOffset'], 31),
    'intermediate_logits': ([1, 'execution', 'commits', 0, 'outputKind'], 'logits'),
    'commit_dtype': ([1, 'execution', 'commits', 2, 'outputDType'], 'float32'),
    'incomplete_commits': ([1, 'execution', 'completedFrames'], 2),
    'state_shape': ([1, 'execution', 'finalState', 'entries', 0, 'shape'], [1, 3, 1]),
    'state_dtype': ([1, 'execution', 'finalState', 'entries', 0, 'dtype'], 'float32'),
    'logit_digest': ([1, 'execution', 'finalLogits', 'logicalBytesSHA256'], '0' * 64),
    'logit_shape': ([1, 'execution', 'finalLogits', 'shape'], [1, 512]),
    'wrong_selected_token': ([1, 'execution', 'selection', 'tokenID'], 2527),
    'selection_request_identity': ([1, 'execution', 'selection', 'requestFingerprint'], '0' * 64),
    'selection_nonfinite': ([1, 'execution', 'selection', 'allLogitsFinite'], False),
    'reference_tie_count': ([1, 'execution', 'referenceMaximumTieCount'], 2),
    'invented_private_byte_comparison': ([1, 'execution', 'nativeLogitBytesCompared'], True),
    'per_frame_capture': ([1, 'execution', 'perFrameStateCaptures'], 3),
    'missing_final_capture': ([1, 'execution', 'finalLogitCaptures'], 0),
    'unretired_request': ([1, 'execution', 'allRequestStateRetired'], False),
    'unreleased_model': ([1, 'modelReleased'], False),
    'throughput_claim': ([1, 'throughputMeasurementValid'], True),
    'transport_claim': ([1, 'execution', 'timing', 'includesTransport'], True),
    'wrong_elapsed': ([1, 'execution', 'timing', 'elapsedNanoseconds'], 999999999),
    'wrong_rate': ([1, 'execution', 'timing', 'promptTokensPerFirstTokenSecond'], 66.0),
    'boolean_uint64': ([1, 'execution', 'timing', 'startUptimeNanoseconds'], True),
    'float_uint64': ([1, 'execution', 'timing', 'startUptimeNanoseconds'], 1e12),
    'overflow_uint64': ([1, 'execution', 'timing', 'startUptimeNanoseconds'], 2**64),
    'negative_close': ([1, 'execution', 'timing', 'postStopThroughRequestCloseNanoseconds'], -1),
    'postclose_deadline': ([1, 'execution', 'timing', 'postStopThroughRequestCloseNanoseconds'], 180*10**9),
    'missing_memory_phase': ([1, 'memory'], []),
    'wrong_memory_phase': ([1, 'memory', 2, 'phase'], 'solo_model_released_cache_cleared'),
    'cache_not_cleared': ([1, 'memory', 3, 'cachedMLXBytes'], 1024),
    'impossible_peak': ([1, 'memory', 2, 'peakMLXBytesSinceProcessStart'], 1),
    'negative_memory': ([1, 'memory', 0, 'activeMLXBytes'], -1),
    'wrong_tensor_budget': ([1, 'conservativeStateAndBoundaryBytes'], 1),
}


def mutation_test(path, value):
    def test(self):
        rows = copy.deepcopy(self.rows)
        setpath(rows, path, value)
        with self.assertRaises(ValueError): self.check(rows)
    return test


for label, (path, value) in MUTATIONS.items():
    setattr(SoloOutputAuditTests, 'test_reject_' + label, mutation_test(path, value))


if __name__ == '__main__':
    unittest.main(verbosity=2)
