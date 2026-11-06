"""Bounded recorded-pair CPU regression checks; immutable native fixture input."""
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import struct
import sys
import unittest
sys.dont_write_bytecode = True
ROOT = Path('/Users/developer/DarkbloomDev/cluster-research')
HELPER = ROOT / 'qwen_layer_stage_recorded_audit.py'
HELPER_SHA = 'ba943e3ec2157447d7725ab3ca030bb398813c82be6d4d4a1024d4fbf98d29e4'
assert hashlib.sha256(HELPER.read_bytes()).hexdigest() == HELPER_SHA
spec = importlib.util.spec_from_file_location('recorded_oracle', HELPER)
audit = importlib.util.module_from_spec(spec); spec.loader.exec_module(audit)
RUN = ROOT / 'runs/qwen-layer-stage-recording-20260913'
receipt = audit.parse_json((RUN / 'receipt.json').read_text())
assert receipt['status'] == 'completed' and receipt['native_calls'][0]['exit_code'] == 0
assert hashlib.sha256((RUN / 'native/stdout.txt').read_bytes()).hexdigest() == receipt['native_records_sha256']
rows = [audit.parse_json(x) for x in (RUN / 'native/stdout.txt').read_text().splitlines()]
CHECKPOINT, REPORT = rows[-2:]
EXPECTED_PATH = ROOT / 'qwen-layer-stage-real9b-expected-20260913.json'
assert hashlib.sha256(EXPECTED_PATH.read_bytes()).hexdigest() == 'da869c797a5f37c264e4f1e1ddcf5c5f021630a9aae672dc2d2fb55ecd967a99'
EXPECTED = audit.parse_json(EXPECTED_PATH.read_text())


def synthetic_real_inventory():
    """Metadata-only receipt fixture: exercises the expected branch, no native claim."""
    source = dict(artifactAggregateSHA256=EXPECTED['artifactAggregateSHA256ClaimedByPinnedManifest'],
        sourceConfigurationSHA256=EXPECTED['configurationSHA256'], sourceParameterLayoutSHA256=EXPECTED['sourceParameterLayoutSHA256'],
        planSHA256='a' * 64, bf16ConversionEnabled=True, embeddingActivationDType='bfloat16',
        sourceModelTensorBytes=EXPECTED['sourceModelTensorBytes'], layerCount=32, vocabularySize=248320)
    loads = copy.deepcopy(REPORT['stageLoads'])
    summaries = []
    for index, load in enumerate(loads):
        for k in ['sourceConfigurationSHA256', 'sourceParameterLayoutSHA256', 'planSHA256', 'sourceModelTensorBytes',
                'bf16ConversionEnabled', 'embeddingActivationDType']:
            load[k] = source[k]
        load['verifiedAggregateSHA256'] = source['artifactAggregateSHA256']
        for k in ['activeTensors', 'activeMappingSHA256', 'activeParameterLayoutSHA256', 'parameterLayoutSHA256',
                'loadedTensorBytes', 'largestHostTensorBytes', 'inertTensorBytes']:
            load[k] = copy.deepcopy(EXPECTED['stages'][index][k])
        responsibilities = {m['path']: m['responsibility'] for m in load['inertModules']}
        load['inertModules'] = sorted([dict(copy.deepcopy(m), responsibility=responsibilities[m['path']])
            for m in EXPECTED['stages'][index]['inertModules']], key=lambda m: m['path'])
        summary = {k: load[k] for k in ['stageIndex', 'constructionConfigurationSHA256', 'stagePlanSHA256',
            'activeMappingSHA256', 'activeParameterLayoutSHA256', 'parameterLayoutSHA256', 'loadedTensorBytes', 'inertTensorBytes']}
        summary.update(activeTensorCount=len(load['activeTensors']), inertTensorCount=sum(len(m['parameters']) for m in load['inertModules']))
        summaries.append(summary)
    common = {k: loads[0][k] for k in ['verifiedAggregateSHA256', 'sourceConfigurationSHA256', 'planSHA256',
        'sourceTensorManifestSHA256', 'sourceModelTensorBytes', 'bf16ConversionEnabled']}
    common.update(schemaVersion=1, sourceTensorCount=927, canonicalTensorCount=927, largestSourceTensorBytes=508559360, stages=summaries)
    for load in loads:
        load['storageCommitment'] = copy.deepcopy(common)
        load['storageCommitmentSHA256'] = audit.digest(audit.canonical(common))
    return source, loads


class RecordedOracleTests(unittest.TestCase):
    def setUp(self):
        self.checkpoint, self.report = copy.deepcopy(CHECKPOINT), copy.deepcopy(REPORT)

    def rejects(self, expression):
        with self.assertRaisesRegex(ValueError, expression):
            audit.check_recorded_pair(self.checkpoint, self.report)

    def test_actual_archived_pair(self):
        self.assertEqual(audit.check_recorded_pair(self.checkpoint, self.report)['independentlyVerifiedNativeLogitPairs'], 4)

    def test_scope_flag(self):
        self.report['throughputMeasurementValid'] = True
        self.rejects('flag differs')

    def test_released_model_flag(self):
        self.checkpoint['baselineModelReleasedBeforeStageLoading'] = False
        self.rejects('flag differs')

    def test_source_mismatch(self):
        self.report['comparison']['source']['artifactAggregateSHA256'] = '0' * 64
        self.rejects('source identity differs')

    def test_local_layer_mapping(self):
        self.report['stageLoads'][1]['activeTensors'][4]['localName'] += '.wrong'
        self.rejects('Local mapping differs')

    def test_active_source_dtype(self):
        tensor = next(x for x in self.report['stageLoads'][0]['activeTensors'] if x['sourceDType'] == 'float16')
        tensor['sourceDType'] = 'float32'
        self.rejects('Loaded dtype policy differs')

    def test_inert_shape(self):
        self.report['stageLoads'][0]['inertModules'][0]['parameters'][0]['shape'] = [128, 1]
        self.rejects('Inactive metadata differs')

    def test_common_storage_digest(self):
        self.report['stageLoads'][0]['storageCommitmentSHA256'] = '0' * 64
        self.rejects('Common commitment SHA differs')

    def test_request_uuid(self):
        self.checkpoint['baseline']['request']['request']['requestID'] = '00000000-0000-0000-0000-000000000000'
        self.rejects('Recorded request fingerprint differs')

    def test_step_token_history(self):
        self.checkpoint['baseline']['request']['steps'][1]['tokenIDs'][0] ^= 1
        self.rejects('frame/token timeline differs')

    def test_baseline_state_shape_same_bytes(self):
        self.checkpoint['baseline']['frames'][0]['state']['entries'][0]['shape'] = [1, 768, 3]
        self.rejects('Independent state component geometry/order differs')

    def test_duplicate_state_component(self):
        entries = self.checkpoint['baseline']['frames'][0]['state']['entries']
        entries[1] = copy.deepcopy(entries[0])
        self.rejects('Independent state component geometry/order differs')

    def test_global_state_hash(self):
        self.report['comparison']['frames'][0]['globalStateSHA256'] = '0' * 64
        self.rejects('Complete state commitment/accounting differs')

    def test_candidate_value_and_fresh_hash(self):
        record = self.report['comparison']['frames'][2]['logits']
        record['values'][0] = 1.0 if record['values'][0] != 1.0 else -1.0
        raw = b''.join(struct.pack('<H', struct.unpack('<I', struct.pack('<f', v))[0] >> 16) for v in record['values'])
        record['logicalBytesSHA256'] = hashlib.sha256(raw).hexdigest()
        self.rejects('Baseline/staged native logit bytes differ')

    def test_source_logit_hash(self):
        self.checkpoint['baseline']['frames'][2]['logits']['logicalBytesSHA256'] = '0' * 64
        self.rejects('Native logit bytes SHA differs')

    def test_native_logit_exact_flag(self):
        self.report['comparison']['frames'][2]['nativeLogitBytesExact'] = False
        self.rejects('flag differs')

    def test_baseline_fingerprint(self):
        self.checkpoint['baseline']['fingerprint'] = '0' * 64
        self.rejects('Complete baseline fingerprint differs')

    def test_residency_observation(self):
        self.checkpoint['memory'][0]['activeMLXBytes'] += 1
        self.rejects('Baseline memory observations changed')

    def test_signed_zero_all_native_dtypes(self):
        self.assertEqual(struct.pack('<f', audit.parse_json('[-0]')[0]), struct.pack('<f', -0.0))
        for dtype, raw in [('float32', struct.pack('<f', -0.0)), ('float16', struct.pack('<e', -0.0)), ('bfloat16', struct.pack('<H', 32768))]:
            with self.subTest(dtype=dtype):
                record = dict(shape=[1,1], dtype=dtype, byteCount=len(raw), logicalBytesSHA256=audit.digest(raw), values=[-0.0])
                self.assertEqual(audit.logical_bytes(record, 1, dtype), raw)
                record['values'] = [0.0]
                with self.assertRaisesRegex(ValueError, 'Native logit bytes SHA differs'):
                    audit.logical_bytes(record, 1, dtype)

    def test_expected_real_inventory_branch(self):
        source, loads = synthetic_real_inventory()
        summary = audit.stage_inventory(source, loads, EXPECTED)
        self.assertEqual(summary['activeTensorBytes'], [2519016704, 2519024896])
        self.assertEqual([len(audit.state_geometry(32, 'bfloat16', t, EXPECTED)) for t in audit.FRONTIERS], [72] * 6)

    def test_expected_real_inventory_mismatch(self):
        source, loads = synthetic_real_inventory()
        wrong = copy.deepcopy(EXPECTED)
        wrong['stages'][0]['activeTensors'][0]['byteCount'] += 4
        with self.assertRaisesRegex(ValueError, 'Independent real stage expectation differs'):
            audit.stage_inventory(source, loads, wrong)

    def test_duplicate_json_key(self):
        with self.assertRaisesRegex(ValueError, 'Duplicate JSON key'):
            audit.parse_json('{"a":1,"a":2}')


REAL_RUN = ROOT / 'runs/qwen-layer-stage-real9b-20260913'
assert hashlib.sha256((REAL_RUN / 'native/stdout.txt').read_bytes()).hexdigest() == 'dac1248a0b02ffa6010cd641834d2a43e1e7c5e92634bc28613fc7f73aaaf551'
REAL_CHECKPOINT, REAL_REPORT = [audit.parse_json(x) for x in (REAL_RUN / 'native/stdout.txt').read_text().splitlines()]


class RealRetainedCountRegression(unittest.TestCase):
    def test_actual_real_recorded_pair(self):
        summary = audit.check_recorded_pair(REAL_CHECKPOINT, REAL_REPORT, EXPECTED)
        self.assertEqual(summary['independentlyVerifiedNativeLogitPairs'], 4)
        self.assertEqual(summary['vocabularySize'], 248320)
        self.assertEqual(summary['stateEntriesPerFrame'], 72)
        self.assertEqual(summary['inventory']['canonicalTensors'], 927)

    def test_raw_header_count_cannot_replace_retained_count(self):
        # Rehash both receipts and the comparison binding so the retained-count
        # semantic assertion, not a stale digest, rejects the old 1291 mistake.
        report = dict(REAL_REPORT, stageLoads=copy.deepcopy(REAL_REPORT['stageLoads']),
            comparison=dict(REAL_REPORT['comparison']))
        for receipt in report['stageLoads']:
            receipt['storageCommitment']['sourceTensorCount'] = 1291
            receipt['storageCommitmentSHA256'] = audit.digest(audit.canonical(receipt['storageCommitment']))
        report['comparison']['stageStorageCommitmentSHA256'] = report['stageLoads'][0]['storageCommitmentSHA256']
        with self.assertRaisesRegex(ValueError, 'Common source accounting differs'):
            audit.check_recorded_pair(REAL_CHECKPOINT, report, EXPECTED)


if __name__ == '__main__':
    unittest.main()
