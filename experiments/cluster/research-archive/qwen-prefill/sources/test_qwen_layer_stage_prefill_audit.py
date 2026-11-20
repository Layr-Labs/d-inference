"""CPU fixtures derived from frozen native reference data, not a new native run."""
import copy
import hashlib
import json
import math
from pathlib import Path
import struct
import tempfile
import unittest

import qwen_layer_stage_prefill_audit as oracle

ROOT = Path(__file__).parent
OLD = ROOT / 'runs/qwen-layer-stage-real9b-20260913/native/stdout.txt'
EXPECTED = ROOT / 'qwen-layer-stage-real9b-expected-20260913.json'


def sha(value): return hashlib.sha256(value.encode()).hexdigest()


def refresh_baseline(baseline):
    request = baseline['request']; spec = request['request']
    simple = sha(f"qwen-stage-request-v1|{spec['requestID'].lower()}|65|32|1")
    request['fingerprint'] = sha('qwen-layer-stage-recorded-request-v1\n' + simple
        + '\nvocabulary=248320\nprompt=' + ','.join(map(str, request['promptTokenIDs'])) + '\nteacher=')
    frame_hashes = []
    for evidence in baseline['frames']:
        f = evidence['frame']
        frame_hashes.append(sha('qwen-recorded-frame-v1\n'
            + f"{f['sequence']}|{f['phase']}|{f['tokenOffset']}|{f['tokenCount']}|{str(f['finalPromptChunk']).lower()}\n"
            + f"tokens={evidence['committedTokens']}\n{evidence['outputKind']}|{evidence['outputShape']}|{evidence['outputDType']}\n"
            + evidence['state']['fingerprint'] + '\n' + (evidence['logits']['logicalBytesSHA256'] if 'logits' in evidence else 'no-logits')))
    baseline['fingerprint'] = sha('qwen-layer-stage-baseline-v1\n' + request['fingerprint'] + '\n'
        + hashlib.sha256(json.dumps(baseline['source'], sort_keys=True, separators=(',', ':')).encode()).hexdigest()
        + '\n' + '\n'.join(frame_hashes))
    return simple


def prospective_fixture(old_rows):
    """Proposed schema populated from old captures; never labelled native output."""
    checkpoint = copy.deepcopy(old_rows[0]); baseline = checkpoint['baseline']
    baseline['request']['request']['requestID'] = '792A64BE-C7A4-48F9-9967-2AD9078D3E52'
    baseline['request']['request']['outputCount'] = 1
    baseline['request']['teacherTokenIDs'] = []
    baseline['request']['steps'] = baseline['request']['steps'][:3]
    baseline['frames'] = baseline['frames'][:3]
    simple = refresh_baseline(baseline)
    report = copy.deepcopy(old_rows[1]); report['kind'] = 'qwen_layer_stage_prefill_report'; report['schemaVersion'] = 1
    report['conservativeStateAndBoundaryBytes'] -= 8 * 2 * 4 * 3 * 4 * 256
    identities = []
    for rank, load in enumerate(report['stageLoads']):
        identities.append(dict(stageIndex=rank, requestFingerprint=simple,
            artifactAggregateSHA256=load['verifiedAggregateSHA256'], storageCommitmentSHA256=load['storageCommitmentSHA256'],
            bf16ConversionEnabled=True, sourceConfigurationSHA256=load['sourceConfigurationSHA256'],
            constructionConfigurationSHA256=load['constructionConfigurationSHA256'], planFingerprint=load['planSHA256'],
            stageFingerprint=load['stagePlanSHA256'], activationDType='bfloat16'))
    request = baseline['request']; frames = []
    for step, old in zip(request['steps'], baseline['frames']):
        commits = []
        for rank in range(2):
            commits.append(dict(identity=identities[rank], recordedRequestFingerprint=request['fingerprint'], frame=step['frame'],
                committedTokens=old['committedTokens'], outputKind='hidden' if rank == 0 else old['outputKind'],
                outputShape=[1, step['frame']['tokenCount'], 4096] if rank == 0 else old['outputShape'], outputDType='bfloat16'))
        frames.append(dict(frame=step['frame'], committedTokens=old['committedTokens'], stageCommits=commits))
    final = baseline['frames'][2]
    token = dict(kind='qwen_layer_stage_prefill_local_token', identity=identities[1],
        recordedRequestFingerprint=request['fingerprint'], frame=final['frame'], committedTokens=65, vocabularySize=248320,
        outputOrdinal=0, selectionPolicy='mlx_argmax_all_axes_with_finite_guard_v1', tokenID=2526,
        logitsShape=[1, 248320], logitsDType='bfloat16', selectionDType='uint32', allLogitsFinite=True)
    metadata = dict(kind='qwen_layer_stage_prefill_final_logits', identity=identities[1],
        recordedRequestFingerprint=request['fingerprint'], frame=final['frame'], committedTokens=65, vocabularySize=248320,
        **{k: v for k, v in final['logits'].items() if k != 'values'})
    report['comparison'] = dict(kind='qwen_layer_stage_prefill_compute_comparison', correctnessOnly=True,
        throughputMeasurementValid=False, sequentialOneProcessOnly=True, nativeBoundaryBytesCopied=True,
        baselineEvidenceSHA256=baseline['fingerprint'], requestSHA256=request['fingerprint'], source=baseline['source'],
        stageStorageCommitmentSHA256=report['stageLoads'][0]['storageCommitmentSHA256'], stageIdentities=identities,
        frames=frames, completedFrames=3, committedTokens=65, token=token,
        tokenComparison=dict(policy='finite_maximum_lowest_vocabulary_index_v1', baselineTokenID=2526,
            selectedTokenID=2526, maximumLogit=18.875, maximumTieCount=1, tokenExact=True),
        finalLogits=metadata, finalState=final['state'], stateMetadataAndDigestsExact=True, nativeLogitBytesExact=True,
        captureCounts=dict(perFrameStateSnapshots=0, perFrameLogitCaptures=0, finalStateSnapshots=2,
            finalLogitCaptures=1, nativeTokenSelections=1, nativeBoundaryCopies=3), allRequestStateRetired=True)
    # JSON serialization removes fixture-only aliases between comparison and baseline.
    return oracle.base_helper().parse_json(json.dumps(checkpoint)), oracle.base_helper().parse_json(json.dumps(report))


class PrefillAuditTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.old, pin = oracle.read_rows(OLD); assert pin == oracle.BASELINE_STDOUT_SHA
        cls.expected = oracle.base_helper().parse_json(EXPECTED.read_text())
        cls.fixture = prospective_fixture(cls.old)

    def check(self, pair=None, old=True):
        a, b = pair or self.fixture
        return oracle.check_prefill_pair(a, b, self.expected,
            self.old[0] if old else None, self.old[1]['stageLoads'] if old else None)

    def reject(self, mutate, old=False):
        pair = copy.deepcopy(self.fixture); mutate(*pair)
        with self.assertRaises(ValueError): self.check(pair, old=old)

    def test_prospective_control_and_old_prefix(self):
        result = self.check()
        self.assertEqual(result['argmaxTokenID'], 2526)
        self.assertEqual(result['reconstructedCandidateNativeRows'], 0)
        self.assertEqual(result['candidateFinalStateComponents'], 72)
        self.assertTrue(result['oldFourOutputControlFirstThreePrefillFramesExact'])
        self.assertFalse(result['throughputQualified'])

    def test_file_wrapper_with_prospective_records(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'prospective.jsonl'
            path.write_text('\n'.join(json.dumps(x) for x in self.fixture) + '\n')
            result = oracle.validate(path, OLD, EXPECTED)
            self.assertEqual(result['oldBaselineStdoutSHA256'], oracle.BASELINE_STDOUT_SHA)

    def test_candidate_full_values_rejected(self):
        self.reject(lambda a,b: b['comparison']['finalLogits'].update(values=[0]))

    def test_intermediate_state_capture_rejected(self):
        self.reject(lambda a,b: b['comparison']['frames'][0].update(state=a['baseline']['frames'][0]['state']))

    def test_native_equality_assertion_required(self):
        self.reject(lambda a,b: b['comparison'].update(nativeLogitBytesExact=False))

    def test_candidate_hash_tamper(self):
        self.reject(lambda a,b: b['comparison']['finalLogits'].update(logicalBytesSHA256='f'*64))

    def test_candidate_final_shape_tamper(self):
        self.reject(lambda a,b: b['comparison']['finalLogits'].update(shape=[248320]))

    def test_baseline_raw_byte_digest_tamper(self):
        self.reject(lambda a,b: a['baseline']['frames'][2]['logits'].update(logicalBytesSHA256='f'*64))

    def test_baseline_not_exactly_bf16(self):
        self.reject(lambda a,b: a['baseline']['frames'][2]['logits']['values'].__setitem__(0, 0.1234567))

    def test_baseline_boolean_logit(self):
        self.reject(lambda a,b: a['baseline']['frames'][2]['logits']['values'].__setitem__(0, True))

    def test_baseline_nonfinite_logit(self):
        self.reject(lambda a,b: a['baseline']['frames'][2]['logits']['values'].__setitem__(0, float('nan')))

    def test_coherent_wrong_selected_token(self):
        def mutate(a,b):
            b['comparison']['token']['tokenID'] = 4087
            b['comparison']['tokenComparison'].update(baselineTokenID=4087, selectedTokenID=4087)
        self.reject(mutate)

    def test_wrong_tie_count(self):
        self.reject(lambda a,b: b['comparison']['tokenComparison'].update(maximumTieCount=2))

    def test_wrong_selection_policy(self):
        self.reject(lambda a,b: b['comparison']['token'].update(selectionDType='int32'))

    def test_wrong_token_context(self):
        self.reject(lambda a,b: b['comparison']['token']['identity'].update(stageIndex=0))

    def test_omitted_state_component(self):
        self.reject(lambda a,b: b['comparison']['finalState']['entries'].pop())

    def test_wrong_state_geometry(self):
        self.reject(lambda a,b: b['comparison']['finalState']['entries'][0].update(shape=[1, 3, 4096]))

    def test_wrong_state_dtype(self):
        self.reject(lambda a,b: b['comparison']['finalState']['entries'][0].update(dtype='float32'))

    def test_coherent_changed_state_still_rejected_by_old_control(self):
        def mutate(a,b):
            state = a['baseline']['frames'][2]['state']; state['entries'][0]['sha256'] = 'f'*64
            state['fingerprint'] = oracle.state_hash(state['entries'], 65)
            b['comparison']['finalState'] = copy.deepcopy(state)
            refresh_baseline(a['baseline'])
            b['comparison']['baselineEvidenceSHA256'] = a['baseline']['fingerprint']
        self.reject(mutate, old=True)

    def test_coherent_prompt_tamper(self):
        def mutate(a,b):
            a['baseline']['request']['promptTokenIDs'][0] += 1
            a['baseline']['request']['steps'][0]['tokenIDs'][0] += 1
            refresh_baseline(a['baseline'])
            b['comparison'].update(requestSHA256=a['baseline']['request']['fingerprint'], baselineEvidenceSHA256=a['baseline']['fingerprint'])
        self.reject(mutate)

    def test_output_count_four_rejected(self):
        self.reject(lambda a,b: a['baseline']['request']['request'].update(outputCount=4))

    def test_teacher_in_prefill_rejected(self):
        self.reject(lambda a,b: a['baseline']['request'].update(teacherTokenIDs=[4087]))

    def test_missing_rank_commit(self):
        self.reject(lambda a,b: b['comparison']['frames'][1]['stageCommits'].pop())

    def test_rank_frontier_tamper(self):
        self.reject(lambda a,b: b['comparison']['frames'][0]['stageCommits'][1].update(committedTokens=64))

    def test_reduced_hidden_width_rejected(self):
        self.reject(lambda a,b: b['comparison']['frames'][0]['stageCommits'][0].update(outputShape=[1, 32, 2048]))

    def test_capture_count_tamper(self):
        self.reject(lambda a,b: b['comparison']['captureCounts'].update(perFrameStateSnapshots=3))

    def test_retirement_and_boolean_schema_types(self):
        self.reject(lambda a,b: b['comparison'].update(allRequestStateRetired=1))
        self.reject(lambda a,b: b.update(schemaVersion=True))

    def test_old_context_capacity_estimate_rejected(self):
        self.reject(lambda a,b: b.update(conservativeStateAndBoundaryBytes=self.old[1]['conservativeStateAndBoundaryBytes']))

    def test_source_namespace_owner_tamper(self):
        self.reject(lambda a,b: b['stageLoads'][1]['activeTensors'][0].update(sourceName='language_model.model.layers.0.linear_attn.A_log'))

    def test_wrong_retained_source_count(self):
        self.reject(lambda a,b: b['stageLoads'][0]['storageCommitment'].update(sourceTensorCount=1291))

    def test_inert_dtype_tamper(self):
        self.reject(lambda a,b: b['stageLoads'][0]['inertModules'][0]['parameters'][0].update(dtype='float32'))

    def test_uncleared_cache_rejected(self):
        self.reject(lambda a,b: b['memory'][-1].update(cachedMLXBytes=1))

    def test_signed_zero_native_reconstruction(self):
        native = struct.pack('<HH', 0x8000, 0)
        values = oracle.base_helper().parse_json('[-0,0]')
        record = dict(shape=[1,2], dtype='bfloat16', byteCount=4,
            logicalBytesSHA256=hashlib.sha256(native).hexdigest(), values=values)
        self.assertEqual(oracle.base_helper().logical_bytes(record, 2, 'bfloat16'), native)
        record['values'][0] = 0
        with self.assertRaises(ValueError): oracle.base_helper().logical_bytes(record, 2, 'bfloat16')

    def test_bounded_duplicate_and_signed_zero_json(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'input.jsonl'
            path.write_text('{"x":-0}\n{}\n')
            rows,_ = oracle.read_rows(path); self.assertEqual(math.copysign(1, rows[0]['x']), -1)
            for text in ['{"x":1,"x":2}\n{}\n', '{}\n', '{}\n{}\n{}\n',
                    '{"x":NaN}\n{}\n', '{"x":'+'['*17+'0'+']'*17+'}\n{}\n']:
                path.write_text(text)
                with self.assertRaises(ValueError): oracle.read_rows(path)


if __name__ == '__main__': unittest.main()
