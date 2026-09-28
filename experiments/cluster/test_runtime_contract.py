"""Reject wrong artifacts and unsafe runs before launching any rank process."""

import copy
import hashlib
import json
from pathlib import Path
import tempfile
import unittest

from runtime import artifacts, configuration


FIXTURE_HASH = 'ee09c4fd6c33d25924f529405950dfc5a9e0393d2b88249f050a8ca9fe3865ec'
FIXTURE_FILES = {
    'config.json': b'{"model_type":"fixture"}\n',
    'metadata/tokenizer.json': b'{"tokens":[0,1]}\n',
    'z-model.bin': bytes([1, 2, 3, 4]),
}


def file_entry(name, content):
    return dict(path=name, size_bytes=len(content), sha256=hashlib.sha256(content).hexdigest())


class ArtifactContractTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.directory = self.root / 'artifact'
        self.directory.mkdir()
        for name, content in FIXTURE_FILES.items():
            path = self.directory / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(content)
        # Deliberately unsorted: the protocol sorts relative paths, not manifest order.
        entries = [file_entry(name, FIXTURE_FILES[name]) for name in reversed(FIXTURE_FILES)]
        self.manifest = dict(schema_version=1, model_id='fixture', files=entries,
                             file_count=len(entries), total_size_bytes=sum(
                                 len(content) for content in FIXTURE_FILES.values()),
                             aggregate_sha256=FIXTURE_HASH)
        self.save_manifest()

    def save_manifest(self):
        (self.directory / 'manifest.json').write_text(json.dumps(self.manifest))

    def test_valid_nested_artifact_uses_registered_aggregate_order(self):
        self.assertEqual(artifacts.verify_model(self.directory, FIXTURE_HASH), FIXTURE_HASH)

    def test_same_size_content_corruption_is_rejected(self):
        (self.directory / 'z-model.bin').write_bytes(bytes([4, 3, 2, 1]))
        with self.assertRaisesRegex(ValueError, 'hash mismatch'):
            artifacts.verify_model(self.directory, FIXTURE_HASH)

    def test_truncated_file_is_rejected(self):
        (self.directory / 'z-model.bin').write_bytes(b'\x01')
        with self.assertRaisesRegex(ValueError, 'size mismatch'):
            artifacts.verify_model(self.directory, FIXTURE_HASH)

    def test_changed_manifest_identity_is_rejected(self):
        with self.assertRaisesRegex(ValueError, 'identity'):
            artifacts.verify_model(self.directory, '0' * 64)

    def test_rewritten_file_hash_cannot_bypass_pinned_aggregate(self):
        replacement = bytes([4, 3, 2, 1])
        (self.directory / 'z-model.bin').write_bytes(replacement)
        for entry in self.manifest['files']:
            if entry['path'] == 'z-model.bin':
                entry['sha256'] = hashlib.sha256(replacement).hexdigest()
        self.save_manifest()
        with self.assertRaisesRegex(ValueError, 'aggregate'):
            artifacts.verify_model(self.directory, FIXTURE_HASH)

    def test_duplicate_and_empty_file_lists_are_rejected(self):
        entry = file_entry('z-model.bin', FIXTURE_FILES['z-model.bin'])
        for entries in ([], [entry, entry.copy()]):
            with self.subTest(entries=entries), self.assertRaises(ValueError):
                artifacts.verify_files(self.directory, entries)

    def test_noncanonical_alias_cannot_count_one_file_twice(self):
        for alias in ('./config.json', 'metadata//tokenizer.json', 'metadata/./tokenizer.json'):
            original = 'config.json' if alias.endswith('config.json') else 'metadata/tokenizer.json'
            entries = [file_entry(original, FIXTURE_FILES[original]),
                       file_entry(alias, FIXTURE_FILES[original])]
            with self.subTest(alias=alias), self.assertRaises(ValueError):
                artifacts.verify_files(self.directory, entries)

    def test_absolute_and_parent_paths_cannot_read_external_files(self):
        outside = self.root / 'outside.bin'
        outside.write_bytes(b'outside')
        for name in (str(outside), '../outside.bin', 'metadata/../../outside.bin', ''):
            with self.subTest(name=name), self.assertRaises(ValueError):
                artifacts.verify_files(self.directory, [file_entry(name, b'outside')])

    def test_file_and_directory_symlinks_cannot_escape_artifact(self):
        # The sibling shares the directory's string prefix; containment must be structural.
        sibling = self.root / 'artifact-neighbor'
        sibling.mkdir()
        outside = sibling / 'weights.bin'
        outside.write_bytes(b'outside')
        (self.directory / 'leaf-link').symlink_to(outside)
        (self.directory / 'directory-link').symlink_to(sibling, target_is_directory=True)
        for name in ('leaf-link', 'directory-link/weights.bin'):
            with self.subTest(name=name), self.assertRaises(ValueError):
                artifacts.verify_files(self.directory, [file_entry(name, b'outside')])

    def test_manifest_counts_must_describe_verified_files(self):
        for field in ('file_count', 'total_size_bytes'):
            with self.subTest(field=field):
                original = self.manifest[field]
                self.manifest[field] = original + 1
                self.save_manifest()
                with self.assertRaises(ValueError):
                    artifacts.verify_model(self.directory, FIXTURE_HASH)
                self.manifest[field] = original

    def test_manifest_schema_and_entry_names_require_json_types(self):
        for version in (True, 1.0, '1', None):
            self.manifest['schema_version'] = version
            self.save_manifest()
            with self.subTest(version=version), self.assertRaises(ValueError):
                artifacts.verify_model(self.directory, FIXTURE_HASH)
        for name in ([], {}, None, 123):
            with self.subTest(name=name), self.assertRaises(ValueError):
                artifacts.verify_files(self.directory, [file_entry(name, b'outside')])


def run_spec(backend='solo', synthetic=True):
    count = 1 if backend == 'solo' else 2
    ranks = [dict(location='local') for _ in range(count)]
    if backend == 'jaccl':
        ranks = [dict(location='ssh', host=f'fixture-node-{index}') for index in range(count)]
    result = dict(schema_version=1, backend=backend, ranks=ranks,
                  workload=dict(synthetic=synthetic, prompt_tokens=17, chunk_size=8,
                                decode_tokens=3, repeats=1, warmups=0, seed=0),
                  timeout_seconds=10)
    if backend in ('jaccl', 'loopback-test'):
        result['workload']['teacher_tokens'] = [4, 5]
    if backend == 'jaccl':
        result.update(coordinator='192.0.2.1:29500', devices=['rdma_en1', 'rdma_en2'])
    if not synthetic:
        result['artifact_aggregate_sha256'] = FIXTURE_HASH
        for index, rank in enumerate(ranks):
            rank['model_directory'] = f'/isolated/model-{index}'
    return result


class RunConfigurationContractTests(unittest.TestCase):
    def validate_json(self, spec):
        return configuration.validate(json.loads(json.dumps(spec)))

    def reject(self, spec):
        with self.assertRaises(ValueError):
            self.validate_json(spec)

    def test_partition_defaults_to_ffn_and_rejects_unknown_plans(self):
        for backend in ('solo', 'replicas', 'jaccl', 'loopback-test'):
            self.assertEqual(self.validate_json(run_spec(backend))['partition'], 'ffn')
        for partition in (None, True, 1, [], {}, '', 'none', 'attention', 'FULL'):
            spec = run_spec('loopback-test')
            spec['partition'] = partition
            with self.subTest(partition=partition):
                self.reject(spec)

    def test_full_partition_requires_cooperation_and_is_passed_to_both_ranks(self):
        for backend in ('solo', 'replicas', 'jaccl', 'loopback-test'):
            spec = run_spec(backend)
            spec['partition'] = 'full'
            if backend in ('solo', 'replicas'):
                self.reject(spec)
                continue
            spec = self.validate_json(spec)
            configs = [configuration.rank_configuration(spec, rank, '/bundle', 'b' * 64, [])
                       for rank in range(2)]
            self.assertEqual(configs[0]['arguments'], configs[1]['arguments'])
            for config in configs:
                index = config['arguments'].index('--partition')
                self.assertEqual(config['arguments'][index + 1], 'full')

    def test_real_json_models_require_an_explicit_valid_artifact_identity(self):
        for value in (None, '', 'a' * 63, 'g' * 64, 123, True):
            spec = run_spec(synthetic=False)
            spec['artifact_aggregate_sha256'] = value
            with self.subTest(value=value):
                self.reject(spec)
        missing = run_spec(synthetic=False)
        del missing['artifact_aggregate_sha256']
        self.reject(missing)

    def test_schema_and_unknown_fields_cannot_silently_change_the_workload(self):
        for version in (True, 1.0, '1', None):
            spec = run_spec()
            spec['schema_version'] = version
            with self.subTest(version=version):
                self.reject(spec)
        for section, field in ((None, 'shell_command'), ('workload', 'decode_token_count'),
                               ('rank', 'command')):
            spec = run_spec()
            target = spec['ranks'][0] if section == 'rank' else spec.get(section, spec)
            target[field] = 'unexpected'
            with self.subTest(section=section):
                self.reject(spec)

    def test_every_real_model_rank_requires_a_nonempty_directory(self):
        for value in (None, '', '   ', 123):
            spec = run_spec('replicas', synthetic=False)
            spec['ranks'][1]['model_directory'] = value
            with self.subTest(value=value):
                self.reject(spec)
        missing = run_spec(synthetic=False)
        del missing['ranks'][0]['model_directory']
        self.reject(missing)

    def test_loopback_rejects_real_weights_and_any_ssh_rank(self):
        self.reject(run_spec('loopback-test', synthetic=False))
        for index in range(2):
            spec = run_spec('loopback-test')
            spec['ranks'][index] = dict(location='ssh', host='fixture-node')
            with self.subTest(index=index):
                self.reject(spec)

    def test_nonpositive_or_noninteger_work_is_rejected(self):
        for field in ('prompt_tokens', 'chunk_size', 'decode_tokens', 'repeats'):
            for value in (0, -1, 1.5, True, '3'):
                spec = run_spec()
                spec['workload'][field] = value
                with self.subTest(field=field, value=value):
                    self.reject(spec)
        for field in ('warmups', 'seed'):
            spec = run_spec()
            spec['workload'][field] = -1
            self.reject(spec)

    def test_deadline_must_be_positive_bounded_integer(self):
        for value in (0, -1, 601, 1.5, True, '90', None):
            spec = run_spec()
            spec['timeout_seconds'] = value
            with self.subTest(value=value):
                self.reject(spec)

    def test_optional_cooperative_teacher_tokens_must_have_valid_shape_and_ids(self):
        for backend in ('jaccl', 'loopback-test'):
            for teacher in ([], [4], [4, 5, 6], [4, -1], [4, True], [4, '5']):
                spec = run_spec(backend)
                spec['workload']['teacher_tokens'] = teacher
                with self.subTest(backend=backend, teacher=teacher):
                    self.reject(spec)
            free_running = run_spec(backend)
            del free_running['workload']['teacher_tokens']
            self.validate_json(free_running)
            one_token = run_spec(backend)
            one_token['workload']['decode_tokens'] = 1
            del one_token['workload']['teacher_tokens']
            self.validate_json(one_token)

    def test_cooperative_rank_payloads_use_one_identical_workload(self):
        hostfile = [['127.0.0.1:29001'], ['127.0.0.1:29002']]
        for backend in ('jaccl', 'loopback-test'):
            spec = self.validate_json(run_spec(backend))
            configs = [configuration.rank_configuration(spec, rank, '/bundle', 'b' * 64, hostfile)
                       for rank in range(2)]
            with self.subTest(backend=backend):
                self.assertEqual(configs[0]['arguments'], configs[1]['arguments'])
                for rank, config in enumerate(configs):
                    self.assertEqual(config['arguments'][:2], ['--mode', 'ffn-tp'])
                    self.assertEqual(config['input_files']['teacher.json'], [4, 5])
                    self.assertEqual(config['environment']['MLX_RANK'], str(rank))
                    self.assertEqual(config['timeout_seconds'], 10)
                    self.assertIn('--teacher-tokens-file', config['arguments'])
                    partition_index = config['arguments'].index('--partition')
                    self.assertEqual(config['arguments'][partition_index + 1], 'ffn')

    def test_supplied_prompt_is_shared_and_defines_its_count(self):
        spec = run_spec('loopback-test')
        spec['workload']['prompt_ids'] = [0, 17, 8, 4]
        del spec['workload']['prompt_tokens']
        spec = self.validate_json(spec)
        self.assertEqual(spec['workload']['prompt_tokens'], 4)
        for rank in range(2):
            config = configuration.rank_configuration(spec, rank, '/bundle', 'b' * 64, [])
            self.assertEqual(config['input_files']['prompt.json'], [0, 17, 8, 4])
            index = config['arguments'].index('--tokens-file')
            self.assertEqual(config['arguments'][index + 1], '@rank/prompt.json')

    def test_supplied_prompt_rejects_invalid_ids_and_explicit_count_mismatch(self):
        for prompt in (None, [], '1,2', [1, -1], [1, True], [1, 2.0], [1, '2']):
            spec = run_spec()
            spec['workload']['prompt_ids'] = prompt
            with self.subTest(prompt=prompt):
                self.reject(spec)
        mismatch = run_spec()
        mismatch['workload']['prompt_ids'] = [1, 2]
        self.reject(mismatch)

    def test_valid_solo_and_replicas_stay_independent_and_keep_artifact_pin(self):
        for backend in ('solo', 'replicas'):
            for synthetic in (False, True):
                spec = self.validate_json(run_spec(backend, synthetic=synthetic))
                with self.subTest(backend=backend, synthetic=synthetic):
                    for rank in range(len(spec['ranks'])):
                        config = configuration.rank_configuration(spec, rank, '/bundle', 'b' * 64, None)
                        self.assertEqual(config['arguments'][:2], ['--mode', 'baseline'])
                        self.assertNotIn('--transport', config['arguments'])
                        self.assertNotIn('--partition', config['arguments'])
                        self.assertNotIn('MLX_RANK', config['environment'])
                        self.assertEqual('--synthetic' in config['arguments'], synthetic)
                        if not synthetic:
                            self.assertEqual(config['artifact_aggregate_sha256'], FIXTURE_HASH)
                            self.assertEqual(config['model_directory'], f'/isolated/model-{rank}')
                            self.assertIn('--model-dir', config['arguments'])

    def test_ssh_aliases_cannot_inject_connection_options_or_shell_syntax(self):
        for host in ('-oProxyCommand=bad', 'user@host', 'host;touch marker',
                     'host$(command)', 'host:22', 'host\nother'):
            spec = run_spec('jaccl')
            spec['ranks'][0]['host'] = host
            with self.subTest(host=host):
                self.reject(spec)

    def test_jaccl_rejects_local_or_repeated_rank_and_invalid_network_contract(self):
        valid = run_spec('jaccl')
        cases = []
        local = copy.deepcopy(valid)
        local['ranks'][0] = dict(location='local')
        cases.append(local)
        repeated = copy.deepcopy(valid)
        repeated['ranks'][1] = repeated['ranks'][0].copy()
        cases.append(repeated)
        for coordinator in ('127.0.0.1:0', '192.0.2.1:65536', 'not-an-address:123', ''):
            spec = copy.deepcopy(valid)
            spec['coordinator'] = coordinator
            cases.append(spec)
        for devices in ([], ['rdma_en1'], ['rdma_en1', 'en2'], ['rdma_en1', '-x']):
            spec = copy.deepcopy(valid)
            spec['devices'] = devices
            cases.append(spec)
        for spec in cases:
            with self.subTest(spec=spec):
                self.reject(spec)


if __name__ == '__main__':
    unittest.main()
