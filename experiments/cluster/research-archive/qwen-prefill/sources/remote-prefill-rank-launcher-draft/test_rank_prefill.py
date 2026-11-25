"""Pure/fake tests; no SSH, real subprocess, socket, model payload, or GPU work."""
import contextlib
import copy
import hashlib
import importlib
import io
import json
from pathlib import Path
import socket
import sys
import tempfile
from types import ModuleType, SimpleNamespace
import unittest
from unittest.mock import patch
import launch_remote_prefill_ranks as launcher
from prefill_compute_archive import digest, write_json
from prefill_compute_inputs import ARTIFACT
from rank_prefill_client import RemoteControl, RemoteMemoryGate, create_remote, prepare_controls
from rank_prefill_contract import configuration, hostfile, validate, peers, Records
from rank_prefill_paths import BOOTSTRAP, PINNED_RUNNER, ABSENT, paths, host_alias, absolute_path
from rank_prefill_staging import prepare_ranks, verify_remote
from rank_prefill_supervision import supervise
from rank_prefill_test_support import PROMPT, EPOCH, ENDPOINTS, Child, fixtures


class Tests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name).resolve()
        for name in ('subprocess.run', 'subprocess.Popen', 'socket.socket'):
            guard = patch(name, side_effect=AssertionError('No actual process or socket creation'))
            guard.start(); self.addCleanup(guard.stop)

    def test_shell_options_and_noncanonical_paths_are_rejected(self):
        for value in ('-oProxyCommand=x', 'x y', 'x;id', 'u@h', ''):
            with self.assertRaises(ValueError): host_alias(value)
        for value in ('relative', '/x/../y', '/x//y', '/x y', '/x/$(id)'):
            with self.assertRaises(ValueError): absolute_path(value)

    def test_hostfile_is_two_distinct_ipv4_loopback_ports(self):
        self.assertEqual(hostfile(ENDPOINTS), ENDPOINTS)
        for value in ([ENDPOINTS[0]] * 2, [['0.0.0.0:3000'], ENDPOINTS[1]], [['127.0.0.1:0'], ENDPOINTS[1]],
                      [['127.0.0.1:65536'], ENDPOINTS[1]], [['127.0.0.1:03100'], ENDPOINTS[1]]):
            with self.assertRaises(ValueError): hostfile(value)

    def bootstrap(self, duplicate=False):
        objects = []
        class FakeSocket:
            def __init__(inner, family, kind):
                self.assertEqual((family, kind), (socket.AF_INET, socket.SOCK_STREAM))
                inner.index, inner.closed = len(objects), False; objects.append(inner)
            def bind(inner, address):
                self.assertEqual(address, ('127.0.0.1', 0))
                self.assertTrue(all(not other.closed for other in objects))
            def getsockname(inner): return ('127.0.0.1', 31001 if duplicate else 31001 + inner.index)
            def close(inner): inner.closed = True
        with patch.object(socket, 'socket', FakeSocket), patch.object(sys, 'argv', ['bootstrap', str(self.path / 'runs'), EPOCH]), \
             contextlib.redirect_stdout(io.StringIO()) as output:
            if duplicate:
                with self.assertRaises(ValueError): exec(BOOTSTRAP, {})
            else:
                exec(BOOTSTRAP, {})
        self.assertEqual(len(objects), 2); self.assertTrue(all(item.closed for item in objects))
        return None if duplicate else json.loads(output.getvalue())

    def test_remote_port_reservations_overlap_then_close(self):
        record = self.bootstrap()
        self.assertEqual(record['hostfile'], ENDPOINTS); self.assertFalse(record['reservationOpen'])
        self.assertTrue(record['raceFailsWithoutFallback'])

    def test_duplicate_port_failure_closes_both_fake_sockets(self):
        self.bootstrap(duplicate=True)

    def test_owned_run_and_scp_destinations_cannot_be_overwritten(self):
        self.bootstrap()
        with patch.object(sys, 'argv', ['bootstrap', str(self.path / 'runs'), EPOCH]):
            with self.assertRaises(FileExistsError): exec(BOOTSTRAP, {})
        with patch.object(sys, 'argv', ['absent', str(self.path / 'runs' / EPOCH)]):
            with self.assertRaises(ValueError): exec(ABSENT, {})

    def test_configuration_binds_policy_rank_ports_and_no_teacher(self):
        for scheduling in ('serial_v1', 'prompt_lookahead_one_v1'):
            configs = [configuration('/run/bundle', 'b' * 64, '/models/fixture', PROMPT, 180, i, EPOCH, scheduling, ENDPOINTS) for i in range(2)]
            self.assertEqual([c['environment']['MLX_RANK'] for c in configs], ['0', '1'])
            for c in configs:
                self.assertEqual(c['input_files']['hosts.json'], ENDPOINTS)
                self.assertEqual(c['arguments'][c['arguments'].index('--stage-prefill-policy') + 1], scheduling)
                self.assertEqual(c['arguments'][c['arguments'].index('--stage-logits-dtype') + 1], 'bfloat16')
                self.assertNotIn('--teacher-tokens-file', c['arguments'])
        for bad in ('native', '', 'auto'):
            with self.assertRaises(ValueError): configuration('/b', 'b' * 64, '/m', PROMPT, 180, 0, EPOCH, bad, ENDPOINTS)

    def test_both_ready_and_final_validate_with_opaque_execution(self):
        for scheduling in ('serial_v1', 'prompt_lookahead_one_v1'):
            for rank in (0, 1):
                rows = fixtures(rank, scheduling)
                validate(rows[0], 0, rank, EPOCH, scheduling, PROMPT)
                validate(rows[1], 1, rank, EPOCH, scheduling, PROMPT, rows[0])

    def test_ready_metadata_mismatches_fail_closed(self):
        for key, value in [('envelopeVersion', 2), ('rank', True), ('worldSize', 1), ('epoch', 'b' * 32),
                           ('modelsReadyAgreementValidated', False), ('freshRequestStateCreated', True)]:
            row = fixtures(0)[0]; row[key] = value
            with self.assertRaises(ValueError): validate(row, 0, 0, EPOCH, 'serial_v1', PROMPT)

    def test_agreement_policy_fingerprint_and_native_dtype_are_bound(self):
        for key, value in [('schedulingPolicy', 'prompt_lookahead_one_v1'), ('nativeDType', 'float32'),
                           ('logitsDType', 'float32'), ('promptCount', 64), ('bf16ConversionEnabled', False)]:
            row = fixtures(0)[0]; row['agreement'][key] = value
            with self.assertRaises(ValueError): validate(row, 0, 0, EPOCH, 'serial_v1', PROMPT)
        row = fixtures(0)[0]; row['agreementFingerprint'] = 'f' * 64
        with self.assertRaises(ValueError): validate(row, 0, 0, EPOCH, 'serial_v1', PROMPT)

    def test_final_release_source_and_history_are_required(self):
        for change in (lambda x: x.update(modelReleased=False), lambda x: x.update(throughputMeasurementValid=True),
                       lambda x: x['request'].update(teacherTokenIDs=[1]),
                       lambda x: x['sourceLoad'].update(verifiedAggregateSHA256='f' * 64)):
            first, final = fixtures(0); change(final)
            with self.assertRaises(ValueError): validate(final, 1, 0, EPOCH, 'serial_v1', PROMPT, first)

    def test_two_rank_configuration_hashes_bind_one_shared_bundle(self):
        layout = paths('/Users/fixture', None, '/models/fixture', EPOCH)
        ranks, controls = prepare_ranks(self.path, layout, 'fixture-peer', 'b' * 64, 'c' * 64, PROMPT, ENDPOINTS, EPOCH, 'serial_v1', 180)
        self.assertEqual([r['rank'] for r in ranks], [0, 1])
        self.assertEqual({r['bundle'] for r in ranks}, {layout['bundle']})
        self.assertNotEqual(controls['ranks'][0]['rank_sha256'], controls['ranks'][1]['rank_sha256'])
        self.assertEqual(controls['ranks'][0]['hostfile_sha256'], controls['ranks'][1]['hostfile_sha256'])

    def test_pinned_control_helpers_reject_tampering(self):
        bundle = self.path / 'bundle'; bundle.mkdir(); (bundle / 'artifacts.py').write_text('# inert fixture\n')
        layout = paths('/Users/fixture', None, '/models/fixture', EPOCH)
        pin = prepare_controls(self.path, layout, dict())
        controls = self.path / 'controls'; (controls / 'artifacts.py').chmod(0o600); (controls / 'artifacts.py').write_text('# altered\n')
        with patch.object(sys, 'argv', ['runner', str(controls / 'control-manifest.json'), pin, 'initial']):
            with self.assertRaises(ValueError): exec(PINNED_RUNNER, {})

    def test_memory_gate_preserves_failed_sample_and_zero_new_swap(self):
        gate = RemoteMemoryGate(); sample = dict(pressure_level=1, swap_used_bytes='0', remote_pid_inventory={})
        gate.consume(sample)
        with self.assertRaises(ValueError): gate.consume(dict(sample, swap_used_bytes='4096'))
        self.assertEqual(len(gate.samples), 2)

    def test_initial_refusal_blocks_bundle_staging_both_workers_and_model_hash(self):
        runtime = self.path / 'repo/experiments/cluster/runtime'; runtime.mkdir(parents=True)
        release = self.path / 'release'; release.mkdir()
        origin = self.path / 'origin'; origin.mkdir()
        inventory = self.path / 'inventory.json'; inventory.write_text('{}')
        output = self.path / 'output'; uploads, operations = [], []
        binary = b'inert CPU-only native fixture'
        def snapshot(source, destination):
            destination.mkdir(); (destination / 'cluster-inference').write_bytes(binary)
            (destination / 'artifacts.py').write_text('# fixture\n')
            write_json(destination / 'bundle.json', dict(files=[dict(path=p.name, sha256=digest(p)) for p in destination.iterdir()]))
            return digest(destination / 'bundle.json')
        def archive(source, destination):
            write_json(destination / 'source-manifest.json', dict(files=[])); return dict(files=[])
        class Refused:
            def __init__(self, *args): pass
            def call(self, operation, timeout):
                operations.append(operation)
                if operation != 'initial': raise AssertionError('Unexpected remote artifact operation')
                return dict(passed=False, actual_free_bytes=5 * 1024**3)
        layout = paths('/Users/fixture', None, '/models/fixture', EPOCH)
        allocation = dict(run=layout['run'], hostfile=ENDPOINTS, reservationOpen=False)
        modules = dict(bundle=SimpleNamespace(snapshot=snapshot), processes=SimpleNamespace())
        args = ['--release', str(release), '--runtime', str(runtime), '--output', str(output), '--input-origin', str(origin),
            '--expected-inventory', str(inventory), '--host', 'fixture-peer', '--remote-model-dir', '/models/fixture',
            '--artifact-aggregate-sha256', ARTIFACT, '--expected-native-sha256', hashlib.sha256(binary).hexdigest(),
            '--stage-prefill-policy', 'serial_v1']
        with patch.object(launcher, 'archive_launcher', return_value=[]), patch.object(launcher, 'archive_sources', side_effect=archive), \
             patch.object(launcher, 'load_archived_runtime', return_value=modules), patch.object(launcher, 'verify_archive'), \
             patch.object(launcher, 'archive_inputs', return_value=dict(prompt=PROMPT, teacher=[], files=[])), \
             patch.object(launcher, 'create_remote', return_value=(layout, allocation)), patch.object(launcher, 'RemoteControl', Refused), \
             patch.object(launcher, 'upload_new', side_effect=lambda *args: uploads.append(args[-1])), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(launcher.main(args), 1)
        self.assertEqual(operations, ['initial']); self.assertEqual(uploads, [layout['controls']])
        receipt = json.loads((output / 'receipt.json').read_text())
        self.assertFalse(receipt['native_execution_attempted']); self.assertNotIn('cohort', receipt)
        self.assertFalse(receipt['model_payload_copies_created'])

    def test_remote_rank_pid_and_rss_observations(self):
        fake = ModuleType('artifacts'); fake.file_sha256, fake.verify_files, fake.verify_model = digest, None, None
        with patch.dict(sys.modules, {'artifacts': fake}): control = importlib.import_module('rank_prefill_control')
        config = dict(bundle='/run/bundle', ranks=[dict(rank=i, directory='/run/rank-' + str(i)) for i in range(2)])
        raw = ''.join('%d 1 %d %d /run/bundle/cluster-inference --tokens-file /run/rank-%d/prompt.json\n' % (50+i, 50+i, 100+i, i) for i in range(2))
        raw += '40 1 40 20 /usr/bin/python3 /run/bundle/rank_worker.py /run/rank-0/rank.json\n'
        rows = control.parse_process_inventory(raw, config)['observed_processes']
        self.assertEqual([(r['kind'], r['rank'], r['rssBytes']) for r in rows], [('native', 0, 102400), ('native', 1, 103424), ('supervisor', 0, 20480)])
        with self.assertRaises(ValueError): control.parse_process_inventory('50 1 50 100 /run/bundle/cluster-inference --bad\n', config)

    def run_fake(self, codes, rows=None, memory=lambda seconds: None, cleanup_failure=False, second_start_failure=False):
        children, clock, stops = [Child(i, code) for i, code in enumerate(codes)], [0], []
        ranks = [dict(rank=i, host='fixture-peer', local=str(self.path / ('rank-' + str(i))), directory='/run/rank-' + str(i)) for i in range(2)]
        for rank in ranks: Path(rank['local']).mkdir(exist_ok=True)
        rows = [fixtures(0), fixtures(1)] if rows is None else rows
        def start(rank):
            i = rank['rank']
            if i == 1 and second_start_failure: raise OSError('second SSH start failed')
            (Path(rank['local']) / 'stdout.jsonl').write_text(''.join(json.dumps(row) + '\n' for row in rows[i]))
            return children[i]
        def stop(values, started):
            stops.append((values, started))
            if cleanup_failure: raise OSError('cancel transport failed')
            for child in started:
                if child.code is None: child.code = -15
        def sleep(seconds): clock[0] += seconds
        result = supervise(ranks, PROMPT, EPOCH, 'serial_v1', 1, start, stop, memory, lambda: clock[0], sleep)
        return result, children, stops

    def test_both_fast_exits_are_drained_and_locally_reaped(self):
        r, children, stops = self.run_fake([0, 0])
        self.assertTrue(r['passed']); self.assertFalse(stops); self.assertEqual(r['local_ssh_client_pids'], [7001, 7002])
        self.assertEqual([p.waits for p in children], [1, 1]); self.assertFalse(r['remote_process_reaping_independently_verified'])

    def test_valid_but_different_peer_agreements_fence_both(self):
        r, _, stops = self.run_fake([None, None], [fixtures(0), fixtures(1, plan='f' * 64)])
        self.assertFalse(r['passed']); self.assertIn('Peers disagree', r['error']); self.assertEqual(len(stops[0][0]), 2)

    def test_peer_ssh_loss_cancels_both_even_if_one_already_exited(self):
        r, _, stops = self.run_fake([255, None], [[], []])
        self.assertEqual(r['exit_codes'][0], 255); self.assertTrue(stops); self.assertFalse(r['passed'])

    def test_deadline_cancels_both_and_bounds_memory_rpc(self):
        timeouts = []; r, _, stops = self.run_fake([None, None], [[], []], lambda seconds: timeouts.append(seconds))
        self.assertEqual(r['cancellation_reason'], 'local_parent_deadline'); self.assertTrue(stops)
        self.assertTrue(all(0 < seconds <= 1 for seconds in timeouts))

    def test_primary_memory_error_survives_cleanup_error(self):
        def failure(seconds): raise ValueError('primary pressure failure')
        r, _, _ = self.run_fake([None, None], [[], []], failure, cleanup_failure=True)
        self.assertIn('primary pressure failure', r['error'])
        self.assertIn('cancel transport failed', r['cleanup_errors'][0]['error']); self.assertFalse(r['passed'])

    def test_second_start_failure_cancels_both_remote_paths(self):
        r, _, stops = self.run_fake([None, None], [[], []], second_start_failure=True)
        self.assertIn('second SSH start failed', r['error']); self.assertEqual(len(stops[0][0]), 2)
        self.assertEqual(len(stops[0][1]), 1); self.assertFalse(r['passed'])

    def test_missing_final_peer_record_fails_closed(self):
        r, _, stops = self.run_fake([0, 0], [fixtures(0), fixtures(1)[:1]])
        self.assertIn('EOF without both', r['error']); self.assertTrue(stops)


if __name__ == '__main__': unittest.main()
