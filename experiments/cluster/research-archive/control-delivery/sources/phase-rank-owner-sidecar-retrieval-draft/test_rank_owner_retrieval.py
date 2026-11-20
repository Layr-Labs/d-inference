import copy
import json
from pathlib import Path
import stat
import tempfile
import unittest
from unittest.mock import patch

from rank_retrieval_fixture import encoded, frozen_layout, make_run, reseal, response, upstream_configuration
from rank_sidecar_admission import admit_run, locations
from rank_sidecar_evidence import canonical
from owner_sidecar_response import decode_response
from retrieve_rank_owner_sidecars import retrieve
from sidecar_files import parse, sha
from sidecar_ssh import SSHReadFailure


class Tests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='rank-sidecar-cpu-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.run, self.receipt, self.pin = make_run(self.root)
        self.context = admit_run(self.run, self.pin)
        for name in ('subprocess.Popen', 'subprocess.run', 'socket.socket'):
            guard = patch(name, side_effect=AssertionError('No real processes or sockets'))
            guard.start()
            self.addCleanup(guard.stop)
    def fake_reader(self, host, path, payload):
        rank = next(item for item in self.context['sidecars'] if item['remote_path'] == path)
        self.assertEqual(host, self.context['host'])
        self.assertIn('os.O_NOFOLLOW', payload)
        metadata, raw = response(rank)
        return encoded(metadata) + raw, b'', dict(local_reader_ssh_client_reaped=True,
            local_reader_ssh_client_pid=888 + rank['rank'], remote_process_reaping_verified=False)
    def changed_receipt_rejected(self, mutate):
        value = copy.deepcopy(self.receipt)
        mutate(value)
        with self.assertRaises((ValueError, KeyError, TypeError)):
            admit_run(self.run, reseal(self.run, value))
    def test_pair_success_exact_bytes_modes_and_roles(self):
        result = retrieve(self.run, self.pin, self.root / 'out', reader=self.fake_reader)
        self.assertTrue(result['passed'])
        self.assertEqual([(row['rank'], row['name']) for row in result['sidecars']],
                         [(0, 'phase'), (0, 'owner'), (1, 'phase'), (1, 'owner')])
        for context, record in zip(self.context['sidecars'], result['sidecars']):
            _, raw = response(context)
            path = self.root / 'out' / record['sidecar']['path']
            self.assertEqual(path.read_bytes(), raw)
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
            self.assertEqual(record['sidecar']['request_correlation']['identity']['role'], 'rank' + str(context['rank']))
        self.assertFalse(result['cross_process_clock_comparison_performed'])
        self.assertFalse(result['remote_process_reaping_verified'])
    def test_lookahead_exact_same_admission_surface(self):
        directory = self.root / 'lookahead'
        directory.mkdir()
        run, _, pin = make_run(directory, policy='prompt_lookahead_one_v1')
        context = admit_run(run, pin)
        self.assertEqual(context['stage_prefill_policy'], 'prompt_lookahead_one_v1')
        self.assertEqual([row['expected_identity']['role'] for row in context['sidecars']], ['rank0', 'rank0', 'rank1', 'rank1'])
    def test_wrong_receipt_pin_blocks_both_ssh_reads(self):
        result = retrieve(self.run, 'f' * 64, self.root / 'out', reader=lambda *args: self.fail('Reader called'))
        self.assertFalse(result['passed'])
        self.assertEqual(result['sidecars'], [])
    def test_existing_output_or_symlink_is_never_overwritten(self):
        output = self.root / 'out'
        output.mkdir()
        for path in (output, self.root / 'link'):
            if path != output:
                path.symlink_to(output)
            with self.assertRaises(FileExistsError):
                retrieve(self.run, self.pin, path, reader=self.fake_reader)
    def test_old_namespace_phase_off_or_cohort_failure_rejected(self):
        for mutate in (lambda r: r.update(kind='remote_qwen_long_prefill_rank_launcher'),
                       lambda r: r.update(phase_timing_requested=False),
                       lambda r: r.update(owner_timing_requested=False),
                       lambda r: r.update(passed=False),
                       lambda r: r.update(source_bundle_raw_inputs_and_remote_model_unchanged_after_run=False),
                       lambda r: r['cohort'].update(passed=False),
                       lambda r: r['cohort'].update(cleanup_errors=['error'])):
            self.changed_receipt_rejected(mutate)
    def test_both_clients_must_be_distinct_reaped_and_successful(self):
        for field, value in [('local_ssh_clients_reaped', [True, False]), ('local_ssh_clients_reaped', [1, 1]),
                             ('exit_codes', [0, 1]), ('exit_codes', [False, 0]), ('local_ssh_client_pids', [12, 12])]:
            self.changed_receipt_rejected(lambda r: r['cohort'].update({field: value}))
        self.changed_receipt_rejected(lambda r: r['cohort']['validation'].update(records_per_rank=[2.0, 2]))
    def test_owned_rank_paths_cannot_swap_alias_or_escape(self):
        for directories in ([self.receipt['remote_paths']['rank_directories'][1]] * 2,
                            list(reversed(self.receipt['remote_paths']['rank_directories'])),
                            ['/tmp/unowned/rank-0', '/tmp/unowned/rank-1']):
            value = copy.deepcopy(self.receipt)
            value['remote_paths']['rank_directories'] = directories
            with self.assertRaises(ValueError):
                locations(value)
        self.changed_receipt_rejected(lambda r: r.update(run_id='f' * 32))
    def test_exact_rank_config_rejects_missing_flag_and_other_rank_environment(self):
        path = self.run / 'rank-1/rank.json'
        original = path.read_bytes()
        for mutate in (lambda r: r['arguments'].__delitem__(slice(-2, None)),
                       lambda r: r['arguments'].__delitem__(slice(-4, -2)),
                       lambda r: r['arguments'].extend(['--prefill-owner-trace-file', '@rank/owner-trace.json']),
                       lambda r: r['arguments'].__setitem__(-1, '@rank/other.json'),
                       lambda r: r['environment'].update(MLX_RANK='0')):
            value = parse(original)
            mutate(value)
            path.write_bytes(encoded(value))
            with self.assertRaises(ValueError):
                admit_run(self.run, reseal(self.run, self.receipt))
    def test_exact_warning_and_two_stdout_records_required(self):
        for relative, extra in [('rank-1/stderr.log', b'other\n'), ('rank-0/stdout.jsonl', b'{}\n')]:
            path = self.run / relative
            original = path.read_bytes()
            path.write_bytes(original + extra)
            with self.assertRaises(ValueError):
                admit_run(self.run, reseal(self.run, self.receipt))
            path.write_bytes(original)
    def test_native_wrong_epoch_rank_boolean_schema_or_failed_retirement(self):
        path = self.run / 'rank-1/stdout.jsonl'
        original = path.read_bytes()
        for mutate in (lambda rows: rows[0].update(rank=0), lambda rows: rows[1].update(epoch='f' * 32),
                       lambda rows: rows[0].update(schemaVersion=True), lambda rows: rows[1].update(modelReleased=False)):
            rows = [parse(line) for line in original.splitlines()]
            mutate(rows)
            path.write_bytes(b''.join(encoded(row) for row in rows))
            with self.assertRaises(ValueError):
                admit_run(self.run, reseal(self.run, self.receipt))
    def test_peer_mismatch_and_source_stage_mismatch_rejected(self):
        path = self.run / 'rank-1/stdout.jsonl'
        original = path.read_bytes()
        for change_agreement in (False, True):
            rows = [parse(line) for line in original.splitlines()]
            if change_agreement:
                for row in rows:
                    row['agreement']['planFingerprint'] = 'f' * 64
                    row['agreementFingerprint'] = sha(b'qwen-profiled-prefill-start-agreement-v1\n' + canonical(row['agreement']))
            else:
                rows[1]['sourceLoad']['stageIndex'] = 0
            path.write_bytes(b''.join(encoded(row) for row in rows))
            with self.assertRaises(ValueError):
                admit_run(self.run, reseal(self.run, self.receipt))
    def test_sidecar_swapped_role_or_request_or_path_rejected(self):
        rank = self.context['sidecars'][0]
        metadata, raw = response(rank)
        with self.assertRaises(ValueError):
            decode_response(encoded(metadata) + raw, self.context['sidecars'][1])
        for field, wrong in [('role', 'rank1'), ('requestFingerprint', 'f' * 64)]:
            trace = parse(raw)
            trace['identity'][field] = wrong
            changed = encoded(trace)
            header = dict(metadata, sha256=sha(changed), size_bytes=len(changed))
            with self.assertRaises(ValueError):
                decode_response(encoded(header) + changed, rank)
    def test_first_read_failure_never_reads_second(self):
        calls = []
        def reader(*args):
            calls.append(args)
            raise SSHReadFailure(dict(operation='read', error='first'), [],
                dict(local_reader_ssh_client_reaped=True), b'partial', b'error')
        result = retrieve(self.run, self.pin, self.root / 'out', reader=reader)
        self.assertFalse(result['passed'])
        self.assertEqual(len(calls), 1)
        self.assertEqual(len(result['sidecars']), 1)
    def test_third_failure_keeps_first_rank_bytes_and_primary_cleanup_distinct(self):
        def reader(host, path, payload):
            if '/rank-0/' in path:
                return self.fake_reader(host, path, payload)
            raise SSHReadFailure(dict(operation='read', error='primary'), [dict(operation='wait', error='cleanup')],
                dict(local_reader_ssh_client_reaped=False), b'partial', b'error')
        result = retrieve(self.run, self.pin, self.root / 'out', reader=reader)
        self.assertFalse(result['passed'])
        self.assertTrue(result['sidecars'][0]['passed'])
        self.assertFalse(result['sidecars'][2]['passed'])
        self.assertEqual(result['primary_failure']['error'], 'primary')
        self.assertEqual(result['primary_failure']['rank'], 1)
        self.assertEqual(result['cleanup_errors'][0]['error'], 'cleanup')
        self.assertTrue((self.root / 'out/rank-0/phase/phase-trace.json').exists())
        self.assertFalse((self.root / 'out/rank-1/phase/phase-trace.json').exists())
    def test_local_pin_mutation_after_first_read_stops_second(self):
        calls = []
        def reader(*args):
            calls.append(args)
            result = self.fake_reader(*args)
            (self.run / 'rank-1/stdout.jsonl').write_bytes(b'changed')
            return result
        result = retrieve(self.run, self.pin, self.root / 'out', reader=reader)
        self.assertFalse(result['passed'])
        self.assertEqual(len(calls), 1)
        self.assertIn('Pinned rank file differs', result['primary_failure']['error'])

    def test_actual_rank_constructor_drives_four_paths_and_rejects_solo_bundle(self):
        layout = frozen_layout(self.receipt['epoch'])
        self.assertEqual(layout, self.receipt['remote_paths'])
        self.assertEqual(layout['bundle'], layout['run'] + '/bundle')
        self.assertEqual([item['remote_path'] for item in self.context['sidecars']],
            [layout['run'] + '/rank-' + str(rank) + '/' + name + '-trace.json'
             for rank in (0, 1) for name in ('phase', 'owner')])
        wrong = copy.deepcopy(self.receipt)
        wrong['remote_paths']['bundle'] = layout['run'] + '/native/bundle'
        for rank in (0, 1):
            value = upstream_configuration(wrong['remote_paths']['bundle'], wrong['bundle_manifest_sha256'],
                layout['model'], wrong['inputs']['prompt_file_sha256'], rank, wrong['epoch'], wrong['stage_prefill_policy'])
            (self.run / ('rank-' + str(rank)) / 'rank.json').write_bytes(encoded(value))
        result = retrieve(self.run, reseal(self.run, wrong), self.root / 'wrong-layout',
                          reader=lambda *args: self.fail('Reader must not run for wrong layout'))
        self.assertFalse(result['passed'])
        self.assertEqual(result['sidecars'], [])

    def test_failure_at_each_position_preserves_only_preceding_successes(self):
        order = [(0, 'phase'), (0, 'owner'), (1, 'phase'), (1, 'owner')]
        for failure_index in range(4):
            calls = []
            def reader(*args):
                index = len(calls)
                calls.append(args[1])
                if index == failure_index:
                    raise SSHReadFailure(dict(operation='read', error='primary'),
                        [dict(operation='wait', error='cleanup')],
                        dict(local_reader_ssh_client_reaped=False), b'partial', b'error')
                return self.fake_reader(*args)
            output = self.root / ('fail-' + str(failure_index))
            result = retrieve(self.run, self.pin, output, reader=reader)
            self.assertFalse(result['passed'])
            self.assertEqual(len(calls), failure_index + 1)
            self.assertEqual([row['passed'] for row in result['sidecars']], [True] * failure_index + [False])
            self.assertEqual((result['primary_failure']['rank'], result['primary_failure']['sidecar']), order[failure_index])
            self.assertEqual(result['primary_failure']['error'], 'primary')
            self.assertEqual(result['cleanup_errors'][0]['error'], 'cleanup')
            for index, (rank, name) in enumerate(order):
                target = output / ('rank-' + str(rank)) / name / (name + '-trace.json')
                self.assertEqual(target.exists(), index < failure_index)

    def test_owner_roles_fixed_frame_count_and_production_clock_correlate(self):
        for context in (self.context['sidecars'][1], self.context['sidecars'][3]):
            metadata, raw = response(context)
            decode_response(encoded(metadata) + raw, context)
            for mutate in (lambda t: t['identity'].update(role='solo'),
                           lambda t: t['identity'].update(role='rank' + str(1 - context['rank'])),
                           lambda t: t['identity'].update(frameSequence=7.0),
                           lambda t: t['identity'].update(tokenOffset=0),
                           lambda t: t.update(events=[{}] * 7),
                           lambda t: t.update(clockSource='injected_test_clock'),
                           lambda t: t.update(gpuKernelTimeAsserted=True)):
                trace = parse(raw)
                mutate(trace)
                changed = encoded(trace)
                header = dict(metadata, sha256=sha(changed), size_bytes=len(changed))
                with self.assertRaises(ValueError):
                    decode_response(encoded(header) + changed, context)

    def test_exact_shared_helpers_and_archived_path_constructor_pin(self):
        here = Path(__file__).parent
        source = here.parent / 'phase-owner-sidecar-retrieval-v2-draft'
        for name in ('phase_sidecar_remote_reader.py', 'owner_sidecar_remote_reader.py',
                     'owner_sidecar_response.py', 'sidecar_ssh.py', 'sidecar_files.py'):
            self.assertEqual((here / name).read_bytes(), (source / name).read_bytes())
        path = self.run / 'launcher/long_rank_paths.py'
        changed = path.read_bytes() + b'\n'
        path.write_bytes(changed)
        value = copy.deepcopy(self.receipt)
        for entry in value['launcher_files']:
            if entry['path'] == 'long_rank_paths.py':
                entry.update(sha256=sha(changed), size_bytes=len(changed))
        with self.assertRaisesRegex(ValueError, 'Frozen rank-owner runtime'):
            admit_run(self.run, reseal(self.run, value))


if __name__ == '__main__':
    unittest.main()
