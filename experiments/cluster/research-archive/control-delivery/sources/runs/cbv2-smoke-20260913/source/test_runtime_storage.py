"""Versioned model identity and unequal storage commitments without native work."""

import copy
import json
from pathlib import Path
import tempfile
import unittest

from runtime import configuration, reports
from runtime import persistent_protocol as protocol
from runtime.partition_storage import commitment_hash, validate_storage
from test_persistent_protocol import EPOCH, ready_fixture
from test_runtime_reports import bind_storage, make_report, make_spec


class PartitionStorageTests(unittest.TestCase):
    def test_unequal_model_shards_require_exact_common_evidence(self):
        for synthetic in (True, False):
            spec = make_spec('loopback-test' if synthetic else 'jaccl', synthetic=synthetic,
                             synthetic_profile='gemma-moe')
            records = [make_report(spec, rank) for rank in range(2)]
            for rank, record in enumerate(records):
                if not synthetic:
                    record.update(modelFamily='gemma4', feedForwardKind='moe')
                    bind_storage(record, selected=[250, 350])
                    record['directShardLoad']['largestHostTensorBytes'] = 210 + rank * 40
                reports.validate_report(record, spec, rank)
            self.assertNotEqual(records[0]['parameterLayoutSHA256'], records[1]['parameterLayoutSHA256'])
            self.assertEqual(self.cohort(records, spec), records)

    def cohort(self, records, spec):
        with tempfile.TemporaryDirectory() as temporary:
            ranks = []
            for rank, record in enumerate(records):
                directory = Path(temporary) / str(rank)
                directory.mkdir()
                (directory / 'stdout.jsonl').write_text(json.dumps(record) + '\n')
                ranks.append(dict(rank=rank, local=str(directory)))
            return reports.reports(ranks, spec)

    def test_commitment_fields_and_types_are_closed(self):
        spec = make_spec('loopback-test', synthetic_profile='gemma-moe')
        good = make_report(spec)
        for key in good['partitionStorage']:
            record = copy.deepcopy(good); del record['partitionStorage'][key]
            with self.subTest(missing=key), self.assertRaises(ValueError):
                reports.validate_report(record, spec, 0)
        for field, values in {
            'schemaVersion': [True, 0, 2], 'sourceTensorManifestSHA256': [None, 'F' * 64, 'g' * 64],
            'sourceModelTensorBytes': [True, 0, -1, '1000', 2**63],
            'sourceFFNTensorBytes': [1001], 'sourceShardedFFNTensorBytes': [601],
            'sourceShardedTensorBytes': [601], 'ranks': [None, [], {}, [good['partitionStorage']['ranks'][0]]],
            'extra': [1],
        }.items():
            for value in values:
                record = copy.deepcopy(good); record['partitionStorage'][field] = value
                with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                    reports.validate_report(record, spec, 0)

    def test_local_layout_rank_order_and_byte_conservation_are_independent(self):
        spec = make_spec('loopback-test', synthetic_profile='gemma-moe')
        for mutate in (
            lambda r: r.update(parameterLayoutSHA256='9' * 64),
            lambda r: r['partitionStorage']['ranks'].reverse(),
            lambda r: r['partitionStorage']['ranks'][1].update(rank=0),
            lambda r: r['partitionStorage']['ranks'][0].update(rank=False),
            lambda r: r['partitionStorage']['ranks'][0].update(selectedShardedTensorBytes=True),
            lambda r: r['partitionStorage']['ranks'][0].update(loadedTensorBytes=700),
            lambda r: r['partitionStorage']['ranks'][1].update(selectedShardedTensorBytes=351, loadedTensorBytes=751),
            lambda r: r['partitionStorage']['ranks'][0].update(extra=1),
        ):
            record = make_report(spec); mutate(record)
            with self.assertRaises(ValueError): reports.validate_report(record, spec, 0)

    def test_each_locally_valid_rank_must_commit_to_same_other_rank(self):
        spec = make_spec('loopback-test', synthetic_profile='gemma-moe')
        records = [make_report(spec, rank) for rank in range(2)]
        records[1]['partitionStorage']['sourceTensorManifestSHA256'] = '8' * 64
        reports.validate_report(records[1], spec, 1)
        with self.assertRaisesRegex(ValueError, 'partitionStorage.*disagree'):
            self.cohort(records, spec)

    def test_real_receipt_cannot_claim_an_unbound_selection_or_source(self):
        spec = make_spec('jaccl', synthetic=False)
        for mutate in (
            lambda r: r['directShardLoad'].update(loadedTensorBytes=650),
            lambda r: r['directShardLoad'].update(sourceModelTensorBytes=1001),
            lambda r: r['directShardLoad'].pop('partitionStorage'),
            lambda r: r['directShardLoad']['partitionStorage']['ranks'][0].update(loadedTensorBytes=650),
            lambda r: r['directShardLoad'].update(verifiedAggregateSHA256='8' * 64),
        ):
            record = make_report(spec); mutate(record)
            with self.assertRaises(ValueError): reports.validate_report(record, spec, 0)

    def test_storage_is_required_only_for_tp_and_must_not_be_null(self):
        for backend in ('solo', 'loopback-test'):
            spec = make_spec(backend)
            record = make_report(spec)
            if backend == 'loopback-test':
                del record['partitionStorage']
                with self.assertRaises(ValueError): reports.validate_report(record, spec, 0)
            for value in (None, {}):
                record['partitionStorage'] = value
                with self.assertRaises(ValueError): reports.validate_report(record, spec, 0)


class ModelFamilyProtocolTests(unittest.TestCase):
    def test_gemma_profiles_bind_distinct_quantization_labels_and_restrict_scope(self):
        for profile, label in [('gemma-moe', 'mixed-w4w8g64'), ('gemma-moe-w8', 'w8g64')]:
            for dtype in ('float32', 'bfloat16'):
                spec = make_spec('loopback-test', synthetic_profile=profile, synthetic_dtype=dtype)
                identities = []
                for rank in range(2):
                    _, ready = ready_fixture(spec, rank)
                    protocol.ready(ready, EPOCH, rank, spec)
                    identities.append(ready['identity'])
                    self.assertEqual(ready['identity']['model'], f'synthetic-gemma4-{label}-seed-7')
                    self.assertEqual(ready['identity']['modelFamily'], 'gemma4')
                self.assertEqual(*identities)
            for changes in ({'partition': 'full'}, {'attention_output_precision': 'float32'}):
                with self.subTest(profile=profile, changes=changes), self.assertRaisesRegex(ValueError, 'Gemma'):
                    make_spec('loopback-test', synthetic_profile=profile, **changes)

    def test_unknown_or_wrong_family_rejected_in_reports_and_ready(self):
        for family in (None, True, [], 'qwen', 'gemma4'):
            spec = make_spec(); record = make_report(spec); record['modelFamily'] = family
            with self.subTest(family=family), self.assertRaises(ValueError): reports.validate_report(record, spec, 0)
            _, ready = ready_fixture(); ready['identity']['modelFamily'] = family
            ready['identitySHA256'] = protocol.hash_frame(ready['identity'])
            with self.assertRaises(protocol.PersistentCohortError): protocol.ready(ready, EPOCH, 0, spec)

    def test_ready_binds_actual_layout_common_layouts_and_storage_digest(self):
        spec = make_spec('loopback-test', synthetic_profile='gemma-moe')
        for mutate in (
            lambda r: r.update(parameterLayoutSHA256='9' * 64),
            lambda r: r['identity'].update(parameterLayoutSHA256s=['c' * 64]),
            lambda r: r['identity']['parameterLayoutSHA256s'].reverse(),
            lambda r: r['identity'].update(partitionStorageSHA256='8' * 64),
            lambda r: r['partitionStorage'].update(sourceTensorManifestSHA256='8' * 64),
            lambda r: r.pop('partitionStorage'),
            lambda r: r.update(partitionStorage=None),
            lambda r: r['identity'].update(parameterLayoutSHA256='c' * 64),
        ):
            _, ready = ready_fixture(spec); mutate(ready)
            ready['identitySHA256'] = protocol.hash_frame(ready['identity'])
            with self.assertRaises(protocol.PersistentCohortError): protocol.ready(ready, EPOCH, 0, spec)

    def test_solo_has_one_layout_and_no_storage_and_v1_is_rejected(self):
        spec, ready = ready_fixture()
        self.assertEqual(protocol.request(EPOCH, 1, 'a', [1], 1, 1, None, False, 5, ready)['version'], 4)
        for mutate in (lambda r: r.update(version=1), lambda r: r.update(version=2), lambda r: r.update(version=3),
                       lambda r: r.update(partitionStorage=None),
                       lambda r: r['identity'].update(partitionStorageSHA256='9' * 64),
                       lambda r: r['identity'].update(parameterLayoutSHA256s=['c' * 64, 'c' * 64])):
            bad = copy.deepcopy(ready); mutate(bad)
            bad['identitySHA256'] = protocol.hash_frame(bad['identity'])
            with self.assertRaises(protocol.PersistentCohortError): protocol.ready(bad, EPOCH, 0, spec)

    def test_commitment_canonical_hash_matches_wire_hash(self):
        record = make_report(make_spec('loopback-test', synthetic_profile='gemma-moe'))
        storage = record['partitionStorage']
        self.assertEqual(commitment_hash(storage), protocol.hash_frame(storage))
        self.assertEqual(commitment_hash(dict(reversed(list(storage.items())))), commitment_hash(storage))
        self.assertEqual(validate_storage(storage, 'ffn', 1, 'e' * 64)['loadedTensorBytes'], 750)


if __name__ == '__main__':
    unittest.main()
