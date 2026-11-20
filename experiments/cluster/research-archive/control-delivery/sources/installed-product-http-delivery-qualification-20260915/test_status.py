"""Fabricated DTO and actual local Python-child checks; never SSH or native."""
import copy
import hashlib
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
import status_capture
from status_validation import EXPECTED_CLUSTER, EXPECTED_CONFIGURATION_SHA256, MAXIMUM_STDOUT, validate


def stopped_report():
    raw = (Path(__file__).parent / 'Fixtures/darkbloom-24.stopped-status.json').read_bytes()
    assert hashlib.sha256(raw).hexdigest() == '7e8de892ea29e9ceec050badc2aa125c264b5644742944f6f35a0d3042be4fd2'
    return json.loads(raw)


def report():
    # Historical stopped evidence stays exact. The new selection and all live
    # observations below are explicitly fabricated for a prospective DTO test.
    value = stopped_report()
    binding = copy.deepcopy(value['saved'])
    binding['clusterID'] = EXPECTED_CLUSTER
    binding['configurationSHA256'] = EXPECTED_CONFIGURATION_SHA256
    value['saved'] = copy.deepcopy(binding)
    assert binding['maximumRequests'] == 16 and binding['maximumLifetimeSeconds'] == 300
    assert [(x['rank'], x['id']) for x in binding['peers']] == [(0, 'darkbloom-24'), (1, 'darkbloom-48')]
    assert binding['prefillSchedule'] == 'one_chunk_lookahead_v1'
    members = [{'peerID': peer['id'], 'rank': peer['rank'],
                'transport': 'localPipes' if peer['rank'] == 0 else 'authenticatedSSH',
                'nativeReady': True, 'requestCapacityBytes': 1 << 30,
                'nativeCleanupObserved': False, 'ownerReleaseAcknowledged': False}
               for peer in binding['peers']]
    session = {'binding': copy.deepcopy(binding), 'phase': 'ready', 'ready': True,
               'observedMembershipEpoch': '11111111-1111-4111-8111-111111111111',
               'observedPrefillSchedule': binding['prefillSchedule'], 'mtpEnabled': False,
               'mtpOffReason': 'runtimeCapabilityDisablesSpeculation', 'members': members,
               'admission': {'remainingLifetimeNanoseconds': 250_000_000_000,
                             'remainingRequests': 16, 'activeRequest': False,
                             'draining': False, 'valid': True}}
    value['live'] = {'schema': 'darkbloom_cluster_status_v1', 'binding': copy.deepcopy(binding),
            'nonce': '22222222-2222-4222-8222-222222222222', 'authenticationConfigured': True,
            'hostPhase': 'serving', 'session': session, 'boundPort': 18081,
            'acquisitions': 0, 'failed': False, 'ready': True,
            'admissionAvailable': True, 'quarantined': False}
    for check in value['checks']:
        if check['name'] == 'localServingObservation':
            check['outcome'] = 'passed'
            check['detail'] = 'Fabricated live observation for source-derived DTO test only'
    value['deviceJournal'] = 'ownershipUnproven'
    return value


def encoded(value):
    return json.dumps(value, separators=(',', ':')).encode()


class StatusTests(unittest.TestCase):
    def test_actual_stopped_report_is_not_live_readiness(self):
        value = stopped_report()
        self.assertEqual(value['saved']['clusterID'], 'darkbloom-product-qwen9b-diagnostics-20260915')
        self.assertEqual(value['saved']['maximumRequests'], 16)
        self.assertEqual(value['saved']['maximumLifetimeSeconds'], 300)
        self.assertEqual([x['id'] for x in value['saved']['peers']], ['darkbloom-24', 'darkbloom-48'])
        self.assertNotIn('live', value)
        with self.assertRaises(ValueError): validate(encoded(value))

    def test_previous_cluster_or_configuration_binding_refuses(self):
        previous = stopped_report()['saved']
        for key in ('clusterID', 'configurationSHA256'):
            value = report()
            for binding in (value['saved'], value['live']['binding'], value['live']['session']['binding']):
                binding[key] = previous[key]
            with self.subTest(key=key), self.assertRaises(ValueError): validate(encoded(value))

    def test_status_command_uses_delivery_runtime(self):
        with tempfile.TemporaryDirectory() as temp:
            with patch.object(status_capture, 'bounded_command', return_value=(encoded(report()), b'', {}, None)) as command:
                status_capture.capture(Path(temp), 'before')
            self.assertEqual(command.call_args[0][0][-1],
                '/Users/developer/DarkbloomDev/installed-distributed-http-delivery-runtime-20260915/darkbloom cluster status --json')

    def test_swift_case_names_and_serial_raw_value_refuse(self):
        for name in ['oneChunkLookahead', 'serial', 'serial_v1']:
            value = report()
            value['saved']['prefillSchedule'] = name
            value['live']['binding']['prefillSchedule'] = name
            value['live']['session']['binding']['prefillSchedule'] = name
            value['live']['session']['observedPrefillSchedule'] = name
            with self.subTest(name=name), self.assertRaises(ValueError): validate(encoded(value))

    def test_fresh_then_one_request_same_epoch(self):
        value = report()
        before = validate(encoded(value))
        value['live']['nonce'] = '33333333-3333-4333-8333-333333333333'
        value['live']['session']['admission']['remainingRequests'] = 15
        after = validate(encoded(value), before)
        self.assertEqual(after['observedMembershipEpoch'], before['observedMembershipEpoch'])
        self.assertEqual(after['nativeReadyRanks'], [0, 1])

    def test_missing_or_wrong_live_identity_refuses(self):
        mutations = [lambda v: v.update(live=None),
                     lambda v: v['saved'].update(clusterID='some-other-cluster'),
                     lambda v: v['live']['session'].update(observedMembershipEpoch=None),
                     lambda v: v['live'].update(ready=False),
                     lambda v: v['live'].update(authenticationConfigured=False),
                     lambda v: v['live']['session']['members'][1].update(nativeReady=False),
                     lambda v: v['live']['session']['members'][1].update(requestCapacityBytes=True),
                     lambda v: v['live']['session']['members'][0].update(nativeCleanupObserved=True)]
        for mutate in mutations:
            value = report(); mutate(value)
            with self.subTest(mutate=mutate), self.assertRaises(ValueError):
                validate(encoded(value))

    def test_saved_success_without_observation_refuses(self):
        value = report()
        next(x for x in value['checks'] if x['name'] == 'localServingObservation')['outcome'] = 'notObserved'
        with self.assertRaises(ValueError): validate(encoded(value))

    def test_stale_epoch_nonce_or_counter_refuses(self):
        before = validate(encoded(report()))
        for mode in ('nonce', 'epoch', 'counter'):
            value = report()
            value['live']['nonce'] = '33333333-3333-4333-8333-333333333333'
            value['live']['session']['admission']['remainingRequests'] = 15
            if mode == 'nonce': value['live']['nonce'] = before['nonce']
            if mode == 'epoch': value['live']['session']['observedMembershipEpoch'] = value['live']['nonce']
            if mode == 'counter': value['live']['session']['admission']['remainingRequests'] = 16
            with self.subTest(mode=mode), self.assertRaises(ValueError): validate(encoded(value), before)

    def test_malformed_duplicate_and_oversize_refuse(self):
        for raw in (b'', b'{}{}', b'{"schema":1,"schema":2}', b'{"x":NaN}', b'x' * (MAXIMUM_STDOUT + 1)):
            with self.subTest(raw=raw[:30]), self.assertRaises(ValueError): validate(raw)

    def test_capture_retains_raw_and_failure_receipt(self):
        with tempfile.TemporaryDirectory() as temp:
            raw = encoded(report()); called = []
            def fake(command):
                called.append(command)
                return raw, b'', {'localProcessReaped': True, 'localExitCode': 0}, None
            with patch.object(status_capture, 'bounded_command', fake):
                result = status_capture.capture(Path(temp), 'before')
            self.assertTrue(result['validated'])
            self.assertIn('cluster status --json', called[0][-1])
            self.assertNotIn('token', called[0][-1])
            self.assertEqual((Path(temp) / 'status-before.stdout.json').read_bytes(), raw)
            self.assertEqual((Path(temp) / 'status-before.stdout.json').stat().st_mode & 0o777, 0o600)
        with tempfile.TemporaryDirectory() as temp:
            with patch.object(status_capture, 'bounded_command', return_value=(b'{}', b'', {'localProcessReaped': True}, None)):
                with self.assertRaises(ValueError): status_capture.capture(Path(temp), 'before')
            self.assertIn('error', json.loads((Path(temp) / 'status-before.receipt.json').read_text()))

    def test_actual_child_success_has_only_local_exit_proof(self):
        raw, err, receipt, failure = status_capture.bounded_command([sys.executable, '-c', 'print("{}")'], timeout=2)
        self.assertIsNone(failure); self.assertEqual(raw, b'{}\n'); self.assertEqual(err, b'')
        self.assertTrue(receipt['localProcessReaped']); self.assertFalse(receipt['remoteNativeCleanupProven'])

    def test_actual_child_partial_output_deadline_reaps(self):
        raw, _, receipt, failure = status_capture.bounded_command(
            [sys.executable, '-c', 'import sys,time;sys.stdout.write("{");sys.stdout.flush();time.sleep(5)'], timeout=0.2)
        self.assertIsInstance(failure, TimeoutError); self.assertEqual(raw, b'{')
        self.assertTrue(receipt['localProcessReaped']); self.assertLess(receipt['elapsedSeconds'], 2)

    def test_actual_child_overflow_is_bounded_and_reaped(self):
        for pipe, count in [('stdout', 70000), ('stderr', 20000)]:
            code = 'import sys;sys.' + pipe + '.write("x"*' + str(count) + ');sys.' + pipe + '.flush()'
            raw, err, receipt, failure = status_capture.bounded_command([sys.executable, '-c', code], timeout=2)
            self.assertIsInstance(failure, ValueError); self.assertTrue(receipt['localProcessReaped'])
            self.assertLessEqual(len(raw), 65536); self.assertLessEqual(len(err), 16384)

    def test_actual_child_nonzero_is_failure(self):
        _, _, receipt, failure = status_capture.bounded_command([sys.executable, '-c', 'raise SystemExit(7)'], timeout=2)
        self.assertIsInstance(failure, RuntimeError); self.assertEqual(receipt['localExitCode'], 7)
        self.assertTrue(receipt['localProcessReaped'])


if __name__ == '__main__':
    unittest.main()
