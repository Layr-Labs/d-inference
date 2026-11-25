"""Changed gates only; all process/network entry points are forbidden."""
import copy
import hashlib
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from long_reference_inputs import archive_inputs, parse_prompt, read_pinned, MAX_PROMPT_BYTES
from long_reference_configuration import configuration, require_rank_configuration, timeout, REQUIRED_ENVIRONMENT
from long_reference_contract import Records, validate_first, validate_final, parse, MAX_STDOUT, MAX_STDERR
from long_reference_artifacts import native_file_receipts
from long_reference_test_fixture import Child, PROMPT, RAW_PROMPT, PROMPT_SHA, inputs, rows
from remote_prefill_client import RemoteMemoryGate
from remote_prefill_supervision import supervise


class Tests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(); self.addCleanup(temp.cleanup)
        self.path = Path(temp.name)
        for name in ('subprocess.run', 'subprocess.Popen', 'socket.socket'):
            guard = patch(name, side_effect=AssertionError('Real process/socket forbidden'))
            guard.start(); self.addCleanup(guard.stop)

    def test_raw_input_is_copied_without_json_rewriting(self):
        prompt = self.path / 'source.json'; prompt.write_bytes(RAW_PROMPT)
        origin = self.path / 'origin.json'; origin.write_bytes(b'opaque independently audited provenance\n')
        pin = hashlib.sha256(origin.read_bytes()).hexdigest()
        record = archive_inputs(prompt, PROMPT_SHA, origin, pin, self.path)
        self.assertEqual((self.path / 'inputs/prompt.json').read_bytes(), RAW_PROMPT)
        self.assertEqual(record['prompt'], PROMPT); self.assertFalse(record['raw_prompt_reencoded'])
        self.assertNotEqual(json.dumps(PROMPT).encode(), RAW_PROMPT)
        self.assertEqual((self.path / 'inputs/prompt-origin.json').read_bytes(), origin.read_bytes())

    def test_raw_pin_and_strict_prompt_types_are_required(self):
        bad = [b'[]', b'[true]', b'[3.0]', b'[3e0]', b'[NaN]', b'[1,]', b'{}',
               b'[' + b'0,' * 8191 + b'-0]', json.dumps([248320] * 8192).encode()]
        for raw in bad:
            with self.subTest(raw=raw[:30]), self.assertRaises(ValueError): parse_prompt(raw)
        p = self.path / 'prompt.json'; p.write_bytes(RAW_PROMPT)
        with self.assertRaises(ValueError): read_pinned(p, 'f' * 64, MAX_PROMPT_BYTES)
        p.write_bytes(json.dumps(PROMPT).encode())
        with self.assertRaises(ValueError): read_pinned(p, PROMPT_SHA, MAX_PROMPT_BYTES)
        link = self.path / 'link'; link.symlink_to(p)
        with self.assertRaises(ValueError): read_pinned(link, PROMPT_SHA, MAX_PROMPT_BYTES)

    def test_growth_after_stat_still_reads_only_the_bound(self):
        p = self.path / 'prompt.json'; p.write_bytes(RAW_PROMPT)
        counts = []
        class Growing(io.BytesIO):
            def read(self, count=-1):
                counts.append(count); return super().read(count)
        with patch.object(Path, 'open', return_value=Growing(b'x' * (MAX_PROMPT_BYTES + 100))):
            with self.assertRaises(ValueError): read_pinned(p, PROMPT_SHA, MAX_PROMPT_BYTES)
        self.assertEqual(counts, [MAX_PROMPT_BYTES + 1])

    def test_fixed_rank_uses_empty_input_map_and_exact_environment(self):
        value = configuration('/bundle', 'b' * 64, '/model', PROMPT_SHA)
        self.assertEqual(value['input_files'], {}); self.assertEqual(value['environment'], REQUIRED_ENVIRONMENT)
        self.assertEqual(value['timeout_seconds'], 300)
        require_rank_configuration(value, '/bundle', 'b' * 64, '/model', PROMPT_SHA)
        for key, replacement in [('input_files', {'prompt.json': PROMPT}), ('timeout_seconds', 330),
                                 ('environment', {'MLX_ENABLE_TF32': '0'})]:
            wrong = copy.deepcopy(value); wrong[key] = replacement
            with self.assertRaises(ValueError): require_rank_configuration(wrong, '/bundle', 'b' * 64, '/model', PROMPT_SHA)
        timeout(330)
        for bad in (0, 331, True, 1.0):
            with self.assertRaises(ValueError): timeout(bad)

    def test_preload_ready_and_final_binding_reject_old_modes_or_clock_fields(self):
        first, last = rows(); validate_first(first, inputs()); validate_final(last, first, inputs())
        for change in [dict(verifiedModelLoaded=True), dict(schemaVersion=1.0), dict(promptFileSHA256='f' * 64),
                       dict(profile='old'), dict(kind='qwen_layer_stage_solo_prefill_ready')]:
            changed = dict(first, **change)
            with self.assertRaises(ValueError): validate_first(changed, inputs())
        for change in [dict(completed=False), dict(modelReleased=False), dict(elapsedNanoseconds=7),
                       dict(memory=[]), dict(kind='qwen_layer_stage_solo_prefill_report')]:
            with self.assertRaises(ValueError): validate_final(dict(last, **change), first, inputs())
        changed = copy.deepcopy(last); changed['evidence']['promptFileSHA256'] = 'f' * 64
        with self.assertRaises(ValueError): validate_final(changed, first, inputs())
        changed = copy.deepcopy(last); changed['memory'][1]['activeMLXBytes'] = True
        with self.assertRaises(ValueError): validate_final(changed, first, inputs())

    def test_records_reject_stderr_extra_partial_duplicate_and_nonfinite_json(self):
        path = self.path / 'stdout.jsonl'
        for contents in [json.dumps(rows()[0]), '\n'.join(json.dumps(x) for x in rows() + rows()[:1]) + '\n']:
            path.write_text(contents)
            with self.assertRaises(ValueError): Records(self.path, inputs()).poll(final=True)
        for raw in ('{"x":1,"x":2}', '{"x":1,"\\u0078":2}', '[Infinity]', '[1e999]'):
            with self.assertRaises(ValueError): parse(raw)
        path.write_text(''.join(json.dumps(x) + '\n' for x in rows()))
        (self.path / 'stderr.log').write_text('diagnostic warning\n')
        with self.assertRaises(ValueError): Records(self.path, inputs()).poll(final=True)

    def test_exact_output_caps_are_checked_before_large_reads_or_hashing(self):
        (self.path / 'native').mkdir()
        for name, maximum in [('stdout.jsonl', MAX_STDOUT), ('stderr.log', MAX_STDERR)]:
            with (self.path / name).open('wb') as f: f.truncate(maximum + 1)
            with self.assertRaises(ValueError): Records(self.path, inputs()).poll()
            (self.path / name).unlink()
            with (self.path / 'native' / name).open('wb') as f: f.truncate(maximum + 1)
        with patch('long_reference_artifacts.digest', side_effect=AssertionError('Oversized output must not be hashed')):
            saved = native_file_receipts(self.path)
        self.assertTrue(all(x['sha256'] is None and x['hash_omitted_because_oversized'] for x in saved))

    def test_zero_swap_and_pressure_gate_retain_failed_sample(self):
        value = dict(pressure_level=2, swap_used_bytes='0', remote_pid_inventory=dict(observed_processes=[]))
        gate = RemoteMemoryGate(); gate.consume(value)
        with self.assertRaises(ValueError): gate.consume(dict(value, swap_used_bytes='1'))
        self.assertEqual(len(gate.samples), 2)
        with self.assertRaises(ValueError): RemoteMemoryGate().consume(dict(value, swap_used_bytes='1'))
        with self.assertRaises(ValueError): RemoteMemoryGate().consume(dict(value, pressure_level=3))

    def run_fake(self, code, observation=lambda seconds: None, cleanup_error=False):
        child, clock, stops = Child(code), [0.0], []
        def start(rank):
            if code == 0: (self.path / 'stdout.jsonl').write_text(''.join(json.dumps(x) + '\n' for x in rows()))
            return child
        def stop(rank, children):
            stops.append(True); child.code = -15
            if cleanup_error: raise OSError('owned cancellation failure')
        def sleep(seconds): clock[0] += seconds
        result = supervise(dict(local=str(self.path)), inputs(), 1, start, stop, observation, lambda: clock[0], sleep)
        return result, child, stops

    def test_success_reaps_only_local_client_without_remote_reap_claim(self):
        result, child, stops = self.run_fake(0)
        self.assertTrue(result['passed']); self.assertEqual(child.waits, 1); self.assertFalse(stops)
        self.assertFalse(result['remote_process_reaping_independently_verified'])

    def test_parent_deadline_and_observation_bound_cancel_owned_run(self):
        bounds = []
        result, _, stops = self.run_fake(None, bounds.append)
        self.assertEqual(result['cancellation_reason'], 'local_parent_deadline'); self.assertTrue(stops)
        self.assertTrue(all(0 < value <= 1 for value in bounds))

    def test_primary_failure_is_preserved_with_cleanup_error(self):
        def fail(seconds): raise ValueError('original memory failure')
        result, _, stops = self.run_fake(None, fail, cleanup_error=True)
        self.assertIn('original memory failure', result['error']); self.assertTrue(stops)
        self.assertEqual(result['cleanup_errors'][0]['operation'], 'stop_owned_run')
        self.assertFalse(result['passed'])

    def test_dead_ssh_client_still_requests_owned_remote_cancel(self):
        result, _, stops = self.run_fake(255)
        self.assertFalse(result['passed']); self.assertTrue(stops)
        self.assertEqual(result['cancellation_reason'], 'native_remote_supervisor_or_ssh_failed')


if __name__ == '__main__': unittest.main()
