"""CPU-only tests: no subprocesses, sockets, native libraries, or model loads."""

import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from stage_p2p_contract import RankRecords, rank_configuration, strict_json, validate_pair
from stage_p2p_memory import MemoryGate
from stage_p2p_supervision import supervise

EPOCH = 'a' * 32


def record(rank_index, kind='stage_p2p_check', **changes):
    value = dict(kind=kind, schemaVersion=1, epoch=EPOCH, rank=rank_index, worldSize=2,
                 transport='loopback-test', backend='ring')
    if kind == 'stage_p2p_check':
        value.update(passed=True, correctnessOnly=True, throughputMeasurementValid=False,
                     fixtureFingerprint='c' * 64, cases=[{'caseID': 'fixture'}])
    value.update(changes)
    return value


class FakeClock:
    def __init__(self): self.value = 0
    def now(self): return self.value
    def sleep(self, amount): self.value += amount


class FakeProcess:
    def __init__(self, pid, code=None): self.pid, self.code, self.waited = pid, code, False
    def poll(self): return self.code
    def wait(self, timeout=None):
        if self.code is None: raise AssertionError('Attempted unbounded fake wait')
        self.waited = True
        return self.code
    def terminate(self): self.code = -15


class LauncherTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.ranks = []
        for i in range(2):
            directory = self.root / str(i)
            directory.mkdir()
            self.ranks.append(dict(rank=i, local=str(directory), directory=str(directory), host=None))
        for target in ('subprocess.Popen', 'subprocess.run', 'socket.socket'):
            blocked = patch(target, side_effect=AssertionError('Real process/socket forbidden in CPU test'))
            blocked.start()
            self.addCleanup(blocked.stop)

    def write(self, rank, values, newline=True):
        data = '\n'.join(json.dumps(value) for value in values) + ('\n' if newline and values else '')
        (Path(self.ranks[rank]['local']) / 'stdout.jsonl').write_text(data)

    def reader(self, rank=0):
        return RankRecords(self.ranks[rank]['local'], rank, EPOCH)

    def run_fake(self, behavior, scenario='success', memory=lambda: None):
        clock, processes, stopped = FakeClock(), [], []
        def start(rank):
            index = rank['rank']
            code, records = behavior(index)
            self.write(index, records)
            process = FakeProcess(100 + index, code)
            processes.append(process)
            return process
        def stop(ranks, children):
            stopped.append([rank['rank'] for rank in ranks])
            for child in children:
                if child.code is None: child.code = -9
                child.wait()
        result = supervise(self.ranks, EPOCH, 2, start, stop, clock.now, clock.sleep,
                           scenario=scenario, memory_check=memory)
        return result, processes, stopped

    def test_exact_native_argv_and_environment(self):
        config = rank_configuration('/bundle', 'b' * 64, 1, EPOCH, 3,
                                    [['127.0.0.1:30001'], ['127.0.0.1:30002']])
        self.assertEqual(config['arguments'], ['--mode', 'stage-p2p-check', '--synthetic',
                         '--transport', 'loopback-test', '--timeout-seconds', '3', '--epoch', EPOCH])
        self.assertEqual(config['environment'], {'MLX_RANK': '1'})
        self.assertEqual(config['environment_files'], {'MLX_HOSTFILE': 'hosts.json'})
        self.assertFalse(config['persistent'])
        self.assertNotIn('model_directory', config)

    def test_reject_invalid_timeout_peer_hosts(self):
        valid = [['127.0.0.1:30001'], ['127.0.0.1:30002']]
        for timeout in (0, 61, True, 1.5):
            with self.subTest(timeout=timeout), self.assertRaises(ValueError):
                rank_configuration('/bundle', 'b' * 64, 0, EPOCH, timeout, valid)
        for hosts in ([['localhost:30001'], ['127.0.0.1:30002']],
                      [['127.0.0.1:30001'], ['127.0.0.1:30001']], [['127.0.0.1:0'], ['127.0.0.1:30002']]):
            with self.assertRaises(ValueError):
                rank_configuration('/bundle', 'b' * 64, 0, EPOCH, 2, hosts)

    def test_optional_ready_then_terminal(self):
        self.write(0, [record(0, 'stage_p2p_ready'), record(0)])
        reader = self.reader()
        reader.poll(final=True)
        self.assertEqual(len(reader.records), 2)

    def test_terminal_without_ready(self):
        self.write(0, [record(0)])
        self.reader().poll(final=True)

    def test_wrong_identity_and_bool_rank_rejected(self):
        for change in ({'epoch': 'b' * 32}, {'rank': True}, {'backend': 'jaccl'},
                       {'worldSize': 1}, {'throughputMeasurementValid': True}, {'schemaVersion': 2}):
            self.write(0, [record(0, **change)])
            with self.assertRaises(ValueError): self.reader().poll(final=True)

    def test_duplicate_nonfinite_and_bad_utf8_rejected(self):
        for data in ('{"x":1,"x":2}', '{"x":NaN}', '{"x":1e999}'):
            with self.assertRaises(ValueError): strict_json(data)
        path = Path(self.ranks[0]['local']) / 'stdout.jsonl'
        path.write_bytes(b'\xff\n')
        with self.assertRaises(UnicodeError): self.reader().poll()

    def test_no_extra_or_duplicate_terminal_records(self):
        for values in ([record(0), record(0)], [record(0, 'stage_p2p_ready')] * 2,
                       [record(0, 'stage_p2p_ready'), record(0), record(0)]):
            self.write(0, values)
            with self.assertRaises(ValueError): self.reader().poll(final=True)

    def test_unterminated_or_missing_final_rejected(self):
        self.write(0, [record(0)], newline=False)
        with self.assertRaises(ValueError): self.reader().poll(final=True)
        self.write(0, [record(0, 'stage_p2p_ready')])
        with self.assertRaises(ValueError): self.reader().poll(final=True)

    def test_peer_fixture_disagreement(self):
        readers = []
        for i in range(2):
            self.write(i, [record(i, fixtureFingerprint=('c' if i == 0 else 'd') * 64)])
            reader = self.reader(i); reader.poll(final=True); readers.append(reader)
        with self.assertRaises(ValueError): validate_pair(readers)

    def test_success_reaps_both_without_cancel(self):
        result, processes, stopped = self.run_fake(lambda i: (0, [record(i, 'stage_p2p_ready'), record(i)]))
        self.assertTrue(result['scenario_passed'])
        self.assertTrue(result['passed'])
        self.assertTrue(all(p.waited for p in processes))
        self.assertFalse(stopped)

    def test_deadline_retires_both(self):
        result, processes, stopped = self.run_fake(lambda i: (None, [record(i, 'stage_p2p_ready')]))
        self.assertEqual(result['cancellation_reason'], 'cohort_deadline')
        self.assertFalse(result['scenario_passed'])
        self.assertEqual(stopped, [[0, 1]])
        self.assertTrue(all(p.poll() is not None for p in processes))

    def test_missing_peer_timeout_is_explicit_negative(self):
        result, processes, stopped = self.run_fake(lambda i: (None, []), scenario='bootstrap-timeout')
        self.assertEqual(len(processes), 1)
        self.assertTrue(result['scenario_passed'])
        self.assertFalse(result['passed'])
        self.assertTrue(stopped)

    def test_ready_peer_loss_retires_other_rank(self):
        result, processes, stopped = self.run_fake(lambda i: (None, [record(i, 'stage_p2p_ready')]), scenario='peer-loss')
        self.assertTrue(result['peer_loss_injected'])
        self.assertTrue(result['scenario_passed'])
        self.assertFalse(result['passed'])
        self.assertTrue(stopped)
        self.assertTrue(all(p.waited for p in processes))

    def test_peer_loss_not_injected_is_not_pass(self):
        result, _, _ = self.run_fake(lambda i: (0, [record(i)]), scenario='peer-loss')
        self.assertFalse(result['scenario_passed'])

    def test_native_crash_retires_live_peer(self):
        result, _, stopped = self.run_fake(lambda i: (1 if i == 0 else None, []))
        self.assertEqual(result['cancellation_reason'], 'rank_failed')
        self.assertTrue(stopped)

    def test_eof_without_terminal_retires_live_peer(self):
        result, _, stopped = self.run_fake(lambda i: (0 if i == 0 else None, []))
        self.assertEqual(result['cancellation_reason'], 'invalid_output_or_startup')
        self.assertTrue(stopped)

    def test_memory_failure_retires_pair(self):
        def fail(): raise ValueError('New swap')
        result, processes, stopped = self.run_fake(lambda i: (None, []), memory=fail)
        self.assertFalse(result['scenario_passed'])
        self.assertTrue(stopped)
        self.assertTrue(all(p.waited for p in processes))

    def test_memory_gate_rejects_pressure_or_new_swap(self):
        def observation(pressure, swap): return dict(pressure_level=pressure, swap_used_bytes=swap)
        for second in (observation(4, '0'), observation(1, '1048576')):
            values = iter([observation(1, '0'), second])
            gate = MemoryGate(lambda: next(values))
            with self.assertRaises(ValueError): gate.observe()


if __name__ == '__main__':
    unittest.main()
