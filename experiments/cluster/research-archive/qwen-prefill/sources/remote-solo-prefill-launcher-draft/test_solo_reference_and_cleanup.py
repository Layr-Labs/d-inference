"""Prospective CPU tests for solo reference staging, record types, and cleanup."""
import copy
import hashlib
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import solo_prefill_reference as reference_owner
from prefill_compute_archive import digest, write_json
from prefill_compute_contract import Records, configuration, parse, validate_first, validate_final
from remote_prefill_client import collect_metadata
from remote_prefill_supervision import supervise
from test_remote_solo_prefill import Child, PROMPT, fixture, reference


class Tests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name)
        for name in ('subprocess.run', 'subprocess.Popen', 'socket.socket'):
            guard = patch(name, side_effect=AssertionError('Real process/socket creation forbidden'))
            guard.start(); self.addCleanup(guard.stop)

    def origin(self):
        value = dict(baselineEvidenceFingerprint=reference_owner.BASELINE_EVIDENCE_SHA256,
            source=reference()['source'], request=dict(promptCount=65, chunkSize=32, outputCount=1,
            vocabularySize=248320, promptTokenIDsSHA256=hashlib.sha256(','.join(map(str, PROMPT)).encode()).hexdigest()))
        raw = json.dumps(value, separators=(',', ':')).encode() + b'\n'
        path = self.path / 'origin.json'; path.write_bytes(raw)
        return value, path, hashlib.sha256(raw).hexdigest()

    def test_reference_original_and_worker_serializations_are_independently_bound(self):
        _, path, pin = self.origin()
        with patch.object(reference_owner, 'ORIGIN_REFERENCE_SHA256', pin):
            ref = reference_owner.archive_reference(path, PROMPT, self.path)
        self.assertFalse(ref['original_and_staged_bytes_identical'])
        self.assertNotEqual(ref['origin_file_sha256'], ref['staged_file_sha256'])
        config = configuration('/bundle', 'b' * 64, '/model', PROMPT, 180, ref)
        rank = self.path / 'rank.json'; write_json(rank, config)
        reference_owner.verify_rank_serialization(rank, ref)
        # Independently mimic the exact pinned worker's load -> dumps -> write.
        worker_text = json.dumps(json.loads(rank.read_text())['input_files']['solo-reference.json'])
        self.assertEqual(worker_text.encode(), (self.path / 'inputs/solo-reference.staged.json').read_bytes())
        self.assertEqual(path.read_bytes(), (self.path / 'inputs/solo-reference.origin.json').read_bytes())
        self.assertEqual(hashlib.sha256(worker_text.encode()).hexdigest(), ref['staged_file_sha256'])

    def test_unknown_origin_pin_and_wrong_prompt_refuse_before_staging(self):
        _, path, pin = self.origin()
        with self.assertRaises(ValueError): reference_owner.archive_reference(path, PROMPT, self.path)
        with patch.object(reference_owner, 'ORIGIN_REFERENCE_SHA256', pin):
            with self.assertRaises(ValueError): reference_owner.archive_reference(path, [4] * 65, self.path)
        self.assertFalse((self.path / 'inputs').exists())

    def test_origin_baseline_pin_must_agree_even_with_file_pin(self):
        value, path, _ = self.origin()
        value['baselineEvidenceFingerprint'] = 'f' * 64
        path.write_text(json.dumps(value)); pin = digest(path)
        with patch.object(reference_owner, 'ORIGIN_REFERENCE_SHA256', pin):
            with self.assertRaises(ValueError): reference_owner.archive_reference(path, PROMPT, self.path)

    def test_bounded_origin_and_symlink_are_refused(self):
        _, path, _ = self.origin()
        link = self.path / 'link'; link.symlink_to(path)
        with self.assertRaises(ValueError): reference_owner.archive_reference(link, PROMPT, self.path)
        path.write_bytes(b'x' * (reference_owner.MAX_REFERENCE_BYTES + 1))
        with self.assertRaises(ValueError): reference_owner.archive_reference(path, PROMPT, self.path)

    def test_origin_growth_after_stat_still_uses_a_bounded_read(self):
        _, path, _ = self.origin()
        counts = []
        class Growing(io.BytesIO):
            def read(self, count=-1):
                counts.append(count)
                return super().read(count)
        contents = Growing(b'x' * (reference_owner.MAX_REFERENCE_BYTES + 100))
        with patch.object(Path, 'open', return_value=contents):
            with self.assertRaises(ValueError): reference_owner.archive_reference(path, PROMPT, self.path)
        self.assertEqual(counts, [reference_owner.MAX_REFERENCE_BYTES + 1])

    def test_rank_reference_arguments_and_bytes_cannot_diverge(self):
        ref = reference()
        config = configuration('/bundle', 'b' * 64, '/model', PROMPT, 180, ref)
        rank = self.path / 'rank.json'; write_json(rank, config)
        reference_owner.verify_rank_serialization(rank, ref)
        config['arguments'][config['arguments'].index('--solo-reference-sha256') + 1] = 'f' * 64
        write_json(rank, config)
        with self.assertRaises(ValueError): reference_owner.verify_rank_serialization(rank, ref)
        config = configuration('/bundle', 'b' * 64, '/model', PROMPT, 180, ref)
        config['input_files']['solo-reference.json']['source']['layerCount'] = 31
        write_json(rank, config)
        with self.assertRaises(ValueError): reference_owner.verify_rank_serialization(rank, reference())

    def test_ready_requires_full_source_native_flags_and_reference_hash(self):
        mutations = [lambda x: x.update(referenceFileSHA256='f' * 64),
            lambda x: x.update(baselineEvidenceFingerprint='f' * 64),
            lambda x: x.update(freshRequestStateCreated=True),
            lambda x: x.update(verifiedModelLoaded=1), lambda x: x.update(schemaVersion=1.0),
            lambda x: x['source'].update(sourceParameterLayoutSHA256='f' * 64),
            lambda x: x['source'].update(bf16ConversionEnabled=1),
            lambda x: x.update(kind='qwen_layer_stage_baseline_checkpoint')]
        for mutate in mutations:
            with self.subTest(mutate=mutate):
                first, _ = fixture(); mutate(first)
                with self.assertRaises(ValueError): validate_first(first, PROMPT, reference())

    def test_final_is_outer_only_but_requires_retirement_and_namespace(self):
        first, last = fixture()
        last['execution'] = {'deliberatelyOpaque': {'futureInnerSchema': 7}}
        validate_final(last, first)
        for key in ('completed', 'allRequestStateRetired', 'modelReleased'):
            changed = copy.deepcopy(last); changed[key] = False
            with self.assertRaises(ValueError): validate_final(changed, first)
        for bad in ([], {}, None):
            changed = copy.deepcopy(last); changed['execution'] = bad
            with self.assertRaises(ValueError): validate_final(changed, first)

    def test_duplicate_escaped_keys_and_fractional_or_boolean_counts_refuse(self):
        for raw in ('{"x":1,"x":2}', '{"x":1,"\\u0078":2}', '[Infinity]', '[1e999]'):
            with self.assertRaises(ValueError): parse(raw)
        for bad in (65.0, True):
            first, _ = fixture(); first['request']['request']['promptCount'] = bad
            with self.assertRaises(ValueError): validate_first(first, PROMPT, reference())

    def test_record_replay_partial_eof_and_size_bounds_refuse(self):
        rows = fixture(); path = self.path / 'stdout.jsonl'
        path.write_text(''.join(json.dumps(row) + '\n' for row in (*rows, rows[1])))
        with self.assertRaises(ValueError): Records(self.path, PROMPT, reference()).poll(final=True)
        path.write_text(json.dumps(rows[0]))
        with self.assertRaises(ValueError): Records(self.path, PROMPT, reference()).poll(final=True)
        path.write_bytes(b'x' * 33)
        with patch('prefill_compute_contract.MAX_LINE', 32):
            with self.assertRaises(ValueError): Records(self.path, PROMPT, reference()).poll()

    def test_primary_observation_error_survives_cancel_and_reap_errors(self):
        child = Child(None)
        child.wait = lambda timeout: (_ for _ in ()).throw(OSError('reap refused'))
        rank = dict(local=str(self.path))
        def stop(ranks, children):
            child.code = -15
            raise OSError('cancel failed')
        def memory(seconds): raise ValueError('original pressure failure')
        result = supervise(rank, PROMPT, reference(), 1, lambda rank: child, stop, memory)
        self.assertEqual(result['cancellation_reason'], 'output_memory_or_ssh_failure')
        self.assertIn('original pressure failure', result['error'])
        self.assertEqual([row['operation'] for row in result['cleanup_errors']],
                         ['stop_owned_run', 'reap_local_ssh_client'])
        self.assertFalse(result['passed']); self.assertFalse(result['local_ssh_client_reaped'])

    def test_native_failure_still_cancels_and_keeps_original_reason(self):
        child = Child(255)
        def stop(*args): raise OSError('cleanup unavailable')
        result = supervise(dict(local=str(self.path)), PROMPT, reference(), 1,
                           lambda rank: child, stop, lambda seconds: None)
        self.assertEqual(result['cancellation_reason'], 'native_remote_supervisor_or_ssh_failed')
        self.assertIsNone(result['error'])
        self.assertEqual(len(result['cleanup_errors']), 1)
        self.assertTrue(result['local_ssh_client_reaped'])

    def test_remote_reference_is_retrieved_and_actual_bytes_verified(self):
        layout = dict(run='/owned', native='/owned/native')
        blobs = {'rank.final.json': b'{}', 'prompt.final.json': b'[3]', 'solo-reference.final.json': b'{"proof":1}'}
        before, after = {}, {}
        for phase, target in (('before', before), ('after', after)):
            target['model_metadata'] = {}
            for name in ('config.json', 'manifest.json'):
                saved = phase + '-' + name; blobs[saved] = saved.encode()
                target['model_metadata'][name] = dict(remote_path='/owned/metadata/' + saved,
                    sha256=hashlib.sha256(blobs[saved]).hexdigest())
        for key, name in (('rank_configuration_sha256', 'rank.final.json'),
                          ('prompt_sha256', 'prompt.final.json'), ('solo_reference_sha256', 'solo-reference.final.json')):
            after[key] = hashlib.sha256(blobs[name]).hexdigest()
        class Process:
            @staticmethod
            def scp(source, destination):
                target = Path(destination); target.write_bytes(blobs[target.name])
        rows = collect_metadata(Process, 'fixture-peer', layout, before, after, self.path)
        saved = next(row for row in rows if row['path'].endswith('solo-reference.final.json'))
        self.assertEqual(saved['sha256'], after['solo_reference_sha256'])


if __name__ == '__main__':
    unittest.main()
