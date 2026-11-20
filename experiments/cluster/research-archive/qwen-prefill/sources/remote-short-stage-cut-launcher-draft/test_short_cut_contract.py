"""Pure/fake cut12 tests; actual processes and sockets are forbidden."""
import copy
import hashlib
import io
import json
import math
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from long_reference_inputs import archive_inputs, parse_tokens, read_pinned, MAX_PROMPT_BYTES
from long_reference_configuration import configuration, require_rank_configuration, timeout, REQUIRED_ENVIRONMENT
from long_reference_contract import Records, validate_first, validate_final, parse, MAX_STDOUT, MAX_STDERR, MAX_LINE
from long_reference_artifacts import native_file_receipts
from short_cut_test_fixture import (Child, PROMPT, TEACHER, RAW_PROMPT, RAW_TEACHER, RAW_ORIGIN,
    RAW_PREFIX, RAW_TEXT, PROMPT_SHA, TEACHER_SHA, inputs, rows, pinned_inputs)
from remote_prefill_client import RemoteMemoryGate
from remote_prefill_paths import paths
from remote_prefill_supervision import supervise


class Tests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(); self.addCleanup(temp.cleanup)
        self.path = Path(temp.name)
        for name in ('subprocess.run', 'subprocess.Popen', 'socket.socket'):
            guard = patch(name, side_effect=AssertionError('Real process/socket forbidden'))
            guard.start(); self.addCleanup(guard.stop)

    def archived(self):
        names = ['prompt.json', 'teacher.json', 'origin.json', 'prefix.json', 'text.txt']
        for name, raw in zip(names, [RAW_PROMPT, RAW_TEACHER, RAW_ORIGIN, RAW_PREFIX, RAW_TEXT]):
            (self.path / name).write_bytes(raw)
        with pinned_inputs():
            return archive_inputs(self.path / names[0], PROMPT_SHA, self.path / names[1], TEACHER_SHA,
                self.path / names[2], hashlib.sha256(RAW_ORIGIN).hexdigest(),
                self.path / names[3], self.path / names[4], self.path)

    def test_both_raw_inputs_and_five_origins_are_preserved(self):
        record = self.archived()
        self.assertEqual((self.path / 'inputs/prompt.json').read_bytes(), RAW_PROMPT)
        self.assertEqual((self.path / 'inputs/teacher.json').read_bytes(), RAW_TEACHER)
        self.assertEqual(record['prompt'], PROMPT); self.assertEqual(record['teacher'], TEACHER)
        self.assertFalse(record['raw_prompt_reencoded']); self.assertFalse(record['raw_teacher_reencoded'])
        self.assertEqual(len(record['files']), 5); self.assertEqual(record['named_teacher_call'], 'cbv2-native')
        self.assertEqual(record['token_ids_hash_encoding'], 'compact_json_integer_array_utf8')
        for name, values in [('prompt', PROMPT), ('teacher', TEACHER)]:
            self.assertEqual(record[name + '_token_ids_sha256'],
                hashlib.sha256(json.dumps(values, separators=(',', ':')).encode()).hexdigest())

    def test_pins_strict_token_types_and_symlinks(self):
        for raw, count in [(b'[]', 65), (b'[true,13,271]', 3), (b'[4087.0,13,271]', 3),
            (b'[4087e0,13,271]', 3), (b'[NaN,13,271]', 3), (b'[-0,13,271]', 3), (b'[248320,13,271]', 3)]:
            with self.subTest(raw=raw), self.assertRaises(ValueError): parse_tokens(raw, count)
        p = self.path / 'prompt'; p.write_bytes(RAW_PROMPT)
        with self.assertRaises(ValueError): read_pinned(p, 'f' * 64, MAX_PROMPT_BYTES)
        link = self.path / 'link'; link.symlink_to(p)
        with self.assertRaises(ValueError): read_pinned(link, PROMPT_SHA, MAX_PROMPT_BYTES)
        p.write_bytes(json.dumps(PROMPT).encode())
        with self.assertRaises(ValueError): read_pinned(p, PROMPT_SHA, MAX_PROMPT_BYTES)

    def test_growth_remains_bounded(self):
        p = self.path / 'prompt'; p.write_bytes(RAW_PROMPT); counts = []
        class Growing(io.BytesIO):
            def read(self, count=-1): counts.append(count); return super().read(count)
        with patch.object(Path, 'open', return_value=Growing(b'x' * (MAX_PROMPT_BYTES + 10))):
            with self.assertRaises(ValueError): read_pinned(p, PROMPT_SHA, MAX_PROMPT_BYTES)
        self.assertEqual(counts, [MAX_PROMPT_BYTES + 1])

    def test_source_derived_solo_layout_and_exact_native_configuration(self):
        source = Path(__file__).with_name('remote_prefill_paths.py')
        self.assertEqual(hashlib.sha256(source.read_bytes()).hexdigest(),
            '2f394109b46b076b9a4a7f99c3dae860ce81e9a3503335e76d6d5520d6e5c7f7')
        layout = paths('/Users/fixture', None, '/models/fixture', 'b' * 32)
        self.assertEqual(layout['bundle'], layout['native'] + '/bundle')
        value = configuration(layout['bundle'], 'b' * 64, layout['model'], PROMPT_SHA, TEACHER_SHA)
        self.assertEqual(value['input_files'], {}); self.assertEqual(value['environment'], REQUIRED_ENVIRONMENT)
        self.assertEqual(value['timeout_seconds'], 180)
        argv = value['arguments']
        for flag, expected in [('--mode', 'qwen-layer-stage-compare'), ('--stage-cut', '12'),
            ('--tokens-file', '@rank/prompt.json'), ('--teacher-tokens-file', '@rank/teacher.json'),
            ('--prompt-tokens', '65'), ('--chunk-size', '32'), ('--decode-tokens', '4')]:
            self.assertEqual(argv.count(flag), 1); self.assertEqual(argv[argv.index(flag) + 1], expected)
        self.assertNotIn('--long-prompt-sha256', argv)
        require_rank_configuration(value, layout['bundle'], 'b' * 64, layout['model'], PROMPT_SHA, TEACHER_SHA)
        for key, replacement in [('input_files', {'teacher.json': TEACHER}), ('timeout_seconds', 300),
                                 ('bundle', layout['run'] + '/bundle'), ('environment', {})]:
            bad = copy.deepcopy(value); bad[key] = replacement
            with self.assertRaises(ValueError):
                require_rank_configuration(bad, layout['bundle'], 'b' * 64, layout['model'], PROMPT_SHA, TEACHER_SHA)
        timeout(210)
        for bad in [0, 211, True, 1.0]:
            with self.assertRaises(ValueError): timeout(bad)

    def test_outer_contract_rejects_mode_input_plan_and_identity_mutations(self):
        first, last = rows(); validate_first(first, inputs()); validate_final(last, first, inputs())
        for change in [dict(kind='qwen_long_prefill_solo_ready'), dict(baselineModelReleasedBeforeStageLoading=False),
                       dict(schemaVersion=1)]:
            with self.assertRaises(ValueError): validate_first(dict(first, **change), inputs())
        for key, value in [('promptTokenIDs', [3] * 65), ('teacherTokenIDs', [1, 2, 3])]:
            bad = copy.deepcopy(first); bad['baseline']['request'][key] = value
            with self.assertRaises(ValueError): validate_first(bad, inputs())
        for change in [dict(kind='qwen_long_prefill_solo_report'), dict(stageModelsReleasedAfterComparison=False),
                       dict(elapsedNanoseconds=7), dict(conservativeStateAndBoundaryBytes=True)]:
            with self.assertRaises(ValueError): validate_final(dict(last, **change), first, inputs())
        for stage, key, value in [(0, 'planSHA256', 'f' * 64), (1, 'stagePlanSHA256', 'f' * 64),
            (1, 'stageIndex', True), (0, 'storageCommitmentSHA256', 'f' * 64)]:
            bad = copy.deepcopy(last); bad['stageLoads'][stage][key] = value
            with self.assertRaises(ValueError): validate_final(bad, first, inputs())
        bad = copy.deepcopy(last); bad['comparison']['requestSHA256'] = 'f' * 64
        with self.assertRaises(ValueError): validate_final(bad, first, inputs())
        # Opaque numeric contents are accepted here only; separate oracle required.
        self.assertEqual(first['baseline']['frames'], [{}] * 6)

    def test_stream_rejects_partial_extra_stderr_duplicate_nonfinite_and_preserves_signed_zero(self):
        path = self.path / 'stdout.jsonl'
        for contents in [json.dumps(rows()[0]), ''.join(json.dumps(x) + '\n' for x in rows() + rows()[:1])]:
            path.write_text(contents)
            with self.assertRaises(ValueError): Records(self.path, inputs()).poll(final=True)
        for raw in ['{"x":1,"x":2}', '{"x":1,"\\u0078":2}', '[Infinity]', '[1e999]']:
            with self.assertRaises(ValueError): parse(raw)
        self.assertEqual(math.copysign(1, parse('[-0]')[0]), -1)
        path.write_text(''.join(json.dumps(x) + '\n' for x in rows()))
        (self.path / 'stderr.log').write_text('extra warning\n')
        with self.assertRaises(ValueError): Records(self.path, inputs()).poll(final=True)

    def test_exact_output_limits_precede_large_reads_or_hashes(self):
        self.assertEqual((MAX_STDOUT, MAX_LINE), (64 * 1024**2, 60 * 1024**2))
        (self.path / 'native').mkdir()
        for name, maximum in [('stdout.jsonl', MAX_STDOUT), ('stderr.log', MAX_STDERR)]:
            with (self.path / name).open('wb') as stream: stream.truncate(maximum + 1)
            with self.assertRaises(ValueError): Records(self.path, inputs()).poll()
            (self.path / name).unlink()
            with (self.path / 'native' / name).open('wb') as stream: stream.truncate(maximum + 1)
        with patch('long_reference_artifacts.digest', side_effect=AssertionError('No large hash')):
            self.assertTrue(all(x['hash_omitted_because_oversized'] for x in native_file_receipts(self.path)))
        with patch('long_reference_contract.MAX_LINE', 4):
            (self.path / 'stdout.jsonl').write_bytes(b'12345')
            with self.assertRaises(ValueError): Records(self.path, inputs()).poll()

    def test_zero_swap_pressure_and_missing_samples_are_not_reclassified(self):
        value = dict(pressure_level=2, swap_used_bytes='0', remote_pid_inventory=dict(observed_processes=[]))
        gate = RemoteMemoryGate(); gate.consume(value)
        for change in [dict(swap_used_bytes='1'), dict(pressure_level=3), dict(pressure_level=True)]:
            with self.assertRaises(ValueError): gate.consume(dict(value, **change))
        self.assertEqual(len(gate.samples), 4)

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

    def test_success_only_reaps_local_client_and_claims_no_numeric_audit(self):
        result, child, stops = self.run_fake(0)
        self.assertTrue(result['passed']); self.assertEqual(child.waits, 1); self.assertFalse(stops)
        self.assertFalse(result['remote_process_reaping_independently_verified'])
        self.assertFalse(result['independent_comparison_oracle_run'])

    def test_parent_deadline_cancels_owned_remote_group(self):
        bounds = []; result, _, stops = self.run_fake(None, bounds.append)
        self.assertEqual(result['cancellation_reason'], 'local_parent_deadline'); self.assertTrue(stops)
        self.assertTrue(all(0 < value <= 1 for value in bounds))

    def test_primary_and_cleanup_failures_remain_separate(self):
        def fail(seconds): raise ValueError('original memory failure')
        result, _, stops = self.run_fake(None, fail, cleanup_error=True)
        self.assertIn('original memory failure', result['error']); self.assertTrue(stops)
        self.assertEqual(result['cleanup_errors'][0]['operation'], 'stop_owned_run')

    def test_dead_client_still_requests_remote_cancel(self):
        result, _, stops = self.run_fake(255)
        self.assertEqual(result['cancellation_reason'], 'native_remote_supervisor_or_ssh_failed'); self.assertTrue(stops)


if __name__ == '__main__': unittest.main()
