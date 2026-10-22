import copy
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from long_reference_configuration import configuration
from long_reference_contract import Records, validate_first, validate_final, MAX_STDOUT
from long_reference_inputs import ARTIFACT, CONFIGURATION, PROFILE, PROFILE_SHA256
from long_pair_cut import PLAN_SHA256, SOURCE_LAYOUT_SHA256, SOURCE_MODEL_BYTES, STAGE_PLAN_SHA256, STAGE_CONFIGURATION_SHA256


def fixture():
    inputs = dict(prompt_file_sha256='a'*64, prompt_token_ids_sha256='b'*64)
    phases = ['before_baseline_load', 'baseline_released_cache_cleared', 'both_stages_loaded',
              'stage_requests_retired_weights_resident', 'stage_models_released_cache_cleared']
    memory = [dict(phase=p, activeMLXBytes=0, cachedMLXBytes=0, peakMLXBytesSinceProcessStart=1) for p in phases]
    reference = dict(kind='qwen_registered9b_long_prefill_reference', correctnessOnly=True,
        throughputMeasurementValid=False, modelReleased=True, allRequestStateRetired=True,
        profile=PROFILE, profileFingerprint=PROFILE_SHA256, promptFileSHA256='a'*64,
        promptTokenIDsSHA256='b'*64, arithmeticEnvironmentSHA256='c'*64, fingerprint='d'*64,
        execution=dict(source=dict(artifactAggregateSHA256=ARTIFACT, sourceConfigurationSHA256=CONFIGURATION,
            planSHA256=PLAN_SHA256, sourceParameterLayoutSHA256=SOURCE_LAYOUT_SHA256,
            sourceModelTensorBytes=SOURCE_MODEL_BYTES, layerCount=32)))
    first = dict(kind='qwen_long_prefill_pair_reference_checkpoint', schemaVersion=1,
                 baselineModelReleasedBeforeStageLoading=True, reference=reference, memory=memory[:2])
    comparison = dict(kind='qwen_long_prefill_pair_comparison', baselineEvidenceFingerprint='d'*64,
        correctnessOnly=True, throughputMeasurementValid=False, interprocessTransportUsed=False,
        physicalTransferQualified=False, allRequestStateRetired=True, completeStateMetadataAndDigestsExact=True,
        finalLogitMetadataAndDigestExact=True, selectedTokenExact=True,
        candidateFullLogitValuesExported=False, candidateNativeBytesComparedDirectly=False,
        frames=[{} for _ in range(16)], finalDigests=[{}, {}],
        agreement=dict(planFingerprint=PLAN_SHA256, producerStageFingerprint=STAGE_PLAN_SHA256[0],
            consumerStageFingerprint=STAGE_PLAN_SHA256[1],
            producerConstructionConfigurationSHA256=STAGE_CONFIGURATION_SHA256[0],
            consumerConstructionConfigurationSHA256=STAGE_CONFIGURATION_SHA256[1],
            storageCommitmentSHA256='f'*64))
    final = dict(kind='qwen_long_prefill_pair_report', schemaVersion=1, correctnessOnly=True,
        throughputMeasurementValid=False, interprocessTransportUsed=False, physicalTransferQualified=False,
        allRequestStateRetired=True, baselineModelReleasedBeforeStageLoading=True, stageModelsReleased=True,
        comparison=comparison, memory=memory,
        stageLoads=[dict(stageIndex=i, verifiedAggregateSHA256=ARTIFACT, sourceConfigurationSHA256=CONFIGURATION,
            planSHA256=PLAN_SHA256, stagePlanSHA256=STAGE_PLAN_SHA256[i],
            constructionConfigurationSHA256=STAGE_CONFIGURATION_SHA256[i],
            sourceParameterLayoutSHA256=SOURCE_LAYOUT_SHA256, sourceModelTensorBytes=SOURCE_MODEL_BYTES,
            storageCommitmentSHA256='f'*64) for i in range(2)])
    return inputs, first, final


class ContractTests(unittest.TestCase):
    def test_pair_command_preserves_raw_input_and_deadline(self):
        c = configuration('/bundle', 'c'*64, '/model', 'a'*64)
        self.assertEqual(c['arguments'][:2], ['--mode', 'qwen-long-prefill-pair-check'])
        self.assertEqual(c['timeout_seconds'], 300)
        self.assertEqual(c['input_files'], {})
        self.assertEqual(c['environment_files'], {})
        self.assertEqual(c['environment'], {'DARKBLOOM_BF16_WEIGHTS':'1',
            'DARKBLOOM_CBV2_ATTN_QUERY_BLOCK':'128','MLX_ENABLE_TF32':'1'})

    def test_complete_outer_records(self):
        inputs, first, final = fixture()
        validate_first(first, inputs); validate_final(final, first, inputs)

    def test_stale_input_or_source(self):
        inputs, first, _ = fixture()
        for key in ['promptFileSHA256', 'promptTokenIDsSHA256', 'profileFingerprint']:
            changed = copy.deepcopy(first); changed['reference'][key] = 'e'*64
            with self.assertRaises(ValueError): validate_first(changed, inputs)
        first['reference']['execution']['source']['artifactAggregateSHA256'] = 'e'*64
        with self.assertRaises(ValueError): validate_first(first, inputs)

    def test_pair_requires_same_reference_and_complete_stage_coverage(self):
        inputs, first, final = fixture()
        variants = [('baselineEvidenceFingerprint', 'e'*64), ('frames', [{}]*15), ('finalDigests', [{}])]
        for key, value in variants:
            changed = copy.deepcopy(final); changed['comparison'][key] = value
            with self.assertRaises(ValueError): validate_final(changed, first, inputs)
        final['stageLoads'].reverse()
        with self.assertRaises(ValueError): validate_final(final, first, inputs)

    def test_no_unperformed_comparison_or_timing_claim(self):
        inputs, first, final = fixture()
        for key in ['candidateFullLogitValuesExported','candidateNativeBytesComparedDirectly','throughputMeasurementValid']:
            changed = copy.deepcopy(final); changed['comparison'][key] = True
            with self.assertRaises(ValueError): validate_final(changed, first, inputs)
        final['seconds'] = 1
        with self.assertRaises(ValueError): validate_final(final, first, inputs)

    def test_retirement_and_memory_phase_binding(self):
        inputs, first, final = fixture()
        for key in ['allRequestStateRetired','stageModelsReleased','baselineModelReleasedBeforeStageLoading']:
            changed = copy.deepcopy(final); changed[key] = False
            with self.assertRaises(ValueError): validate_final(changed, first, inputs)
        final['memory'][0]['activeMLXBytes'] = 1
        # fixture shares dictionaries, so compare to an independent checkpoint.
        original = fixture()[1]
        with self.assertRaises(ValueError): validate_final(final, original, inputs)

    def test_complete_stream_and_incomplete_or_extra_records(self):
        inputs, first, final = fixture()
        data = (json.dumps(first)+'\n'+json.dumps(final)+'\n').encode()
        with tempfile.TemporaryDirectory() as d:
            p = Path(d)/'stdout.jsonl';p.write_bytes(data)
            reader=Records(d,inputs);reader.poll(final=True);self.assertEqual(len(reader.rows),2)
            for invalid in [data[:-1], data+json.dumps(final).encode()+b'\n', json.dumps(first).encode()+b'\n']:
                p.write_bytes(invalid)
                with self.assertRaises(ValueError): Records(d,inputs).poll(final=True)

    def test_output_cap_and_stderr(self):
        inputs, _, _ = fixture()
        with tempfile.TemporaryDirectory() as d:
            p=Path(d)/'stdout.jsonl'
            with p.open('wb') as f: f.truncate(MAX_STDOUT+1)
            with self.assertRaises(ValueError): Records(d,inputs).poll()
            p.unlink();(Path(d)/'stderr.log').write_text('failure')
            with self.assertRaises(ValueError): Records(d,inputs).poll()


if __name__ == '__main__':
    # Test helpers have no reason to launch processes or contact a host.
    with patch('subprocess.Popen', side_effect=AssertionError('No external process in CPU tests')):
        unittest.main()
