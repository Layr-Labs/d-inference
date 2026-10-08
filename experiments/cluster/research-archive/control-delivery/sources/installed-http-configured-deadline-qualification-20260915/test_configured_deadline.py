"""Model-free transaction/file/DTO checks; no SSH, compiler or native process."""
import base64
import copy
import json
import hashlib
from pathlib import Path
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import configuration_remote as remote
from configuration_files import digest, locked, publish, read_private
from configuration_transaction import HOSTS, transact
from harness.terminal_contract import validate_client, observation_qualified
from test_terminal import complete_receipt
from run_configured import bundled_remote, recovery_pins


class DeadlineContractTests(unittest.TestCase):
    def test_two_second_error_preserves_original_sla(self):
        for code, cause in [('deadline_unreachable', None), ('inference_error', 'safety_deadline')]:
            receipt = complete_receipt()
            error = receipt['measurement']['typed_error']
            error['code'] = code
            if cause:
                error['terminal_cause'] = cause
                error['message'] = 'Distributed generation did not complete'
            receipt['measurement']['typed_error_received_ns'] = 2_100_000_000
            observed = validate_client(receipt, 1)
            self.assertTrue(observed['errorReceivedAfterConfiguredCutoff'])
            self.assertFalse(observed['errorReceivedAfterContentCutoff'])
            self.assertFalse(observed['inferenceRequestSucceeded']); self.assertFalse(observed['slaPassed'])
            self.assertFalse(observed['naturalContentDeadlineMissReproduced'])
            for row in receipt['measurement']['content_sla'].values():
                self.assertEqual(row['deadline_ns'], 18_192_000_000)
                self.assertFalse(row['request_passed'])

    def test_other_failure_or_changed_sla_does_not_qualify(self):
        for cause in ['prefill_stall', 'engine_error', 'cancelled', 'decode_stall']:
            receipt = complete_receipt()
            receipt['measurement']['typed_error'].update(code='inference_error', terminal_cause=cause)
            with self.assertRaises(ValueError): validate_client(receipt, 1)
        receipt = complete_receipt()
        receipt['measurement']['content_sla']['declared_prompt_tokens']['deadline_ns'] = 2_000_000_000
        with self.assertRaises(ValueError): validate_client(receipt, 1)

    def test_qualification_requires_cleanup_and_no_observation_intervention(self):
        receipt = complete_receipt(); receipt['measurement']['typed_error_received_ns'] = 2_100_000_000
        record = dict(configuredRequestTimeoutSeconds=2, terminalObservation=validate_client(receipt, 1),
                      statusBefore=dict(validated=True), selfRetirement=dict(self_retirement_observed=True,
                      harness_interference_observed=False), supervisorNaturalFailureExitObserved=True,
                      nativeProcessesAbsent=True, journalsEmpty=True, aliasCleanup=dict(restored=True),
                      guardErrors=[], monitors=[dict(exitCode=0, errors=[])] * 2, pinsUnchanged=True)
        self.assertTrue(observation_qualified(record))
        for mutation in [lambda x: x['selfRetirement'].update(harness_interference_observed=True),
                         lambda x: x['selfRetirement'].update(self_retirement_observed=False),
                         lambda x: x.update(journalsEmpty=False), lambda x: x.update(nativeProcessesAbsent=False),
                         lambda x: x.update(supervisorNaturalFailureExitObserved=False),
                         lambda x: x.update(monitors=[]), lambda x: x.update(guardErrors=['refused']),
                         lambda x: x['terminalObservation'].update(errorReceivedAfterConfiguredCutoff=False),
                         lambda x: x.update(error='retained failure')]:
            value = copy.deepcopy(record); mutation(value)
            self.assertFalse(observation_qualified(value))


class TransactionOrderTests(unittest.TestCase):
    def test_partial_failures_attempt_both_restorations(self):
        for fault in [('prepare', HOSTS[1]), ('install', HOSTS[1]), ('physical', None)]:
            calls = []
            def action(host, operation, pin):
                calls.append((operation, host, pin))
                if (operation, host) == fault: raise RuntimeError('fabricated')
                return dict(afterSHA256=host, restored=operation == 'restore')
            def physical():
                if fault[0] == 'physical': raise KeyboardInterrupt('fabricated')
                return dict(terminalObservationQualified=True)
            result = transact(action, physical)
            self.assertEqual([c[1] for c in calls if c[0] == 'restore'], list(HOSTS))
            self.assertTrue(result['defaultsRestored']); self.assertFalse(result['qualified'])
            self.assertIsNotNone(result['error'])

    def test_failed_restore_does_not_skip_other_host_or_claim_success(self):
        calls = []
        def action(host, operation, pin):
            calls.append((operation, host))
            if operation == 'restore' and host == HOSTS[0]: raise RuntimeError('unreachable')
            return dict(afterSHA256=host, restored=operation == 'restore')
        result = transact(action, lambda: dict(terminalObservationQualified=True))
        self.assertEqual(calls[-1], ('restore', HOSTS[1]))
        self.assertFalse(result['defaultsRestored']); self.assertFalse(result['qualified'])

    def test_restore_only_and_unexpected_inference_success_are_distinct(self):
        calls = []
        def action(host, operation, pin):
            calls.append((operation, host, pin)); return dict(restored=True, afterSHA256=host)
        restored = transact(action, lambda: self.fail('must not run'), prepared={HOSTS[0]: 'held'}, restore_only=True)
        self.assertEqual([c[0] for c in calls], ['restore', 'restore'])
        self.assertEqual(calls[0][2], 'held'); self.assertTrue(restored['qualified'])
        result = transact(action, lambda: dict(terminalObservationQualified=False,
                                               inferenceRequestSucceeded=True, slaPassed=True))
        self.assertFalse(result['qualified']); self.assertTrue(result['physical']['inferenceRequestSucceeded'])


class ConfigurationFileTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='.configuration-check-', dir=Path(__file__).resolve().parent)
        self.root = Path(self.temporary.name)
        self.home = self.root / 'home'; self.runtime = self.root / 'runtime'
        self.provider = self.home / '.config/darkbloom/provider.toml'
        self.device = self.home / '.darkbloom/cluster-device/native-device.lease'
        for parent in [self.provider.parent, self.device.parent, self.runtime]:
            parent.mkdir(mode=0o700, parents=True)
        self.before = b'untouched = "original"\n'; self.after = b'untouched = "original"\ncluster = "temporary"\n'
        publish(self.provider, self.before); publish(self.provider.with_name('provider.toml.lock'), b'')
        publish(self.device, b''); publish(self.runtime / 'darkbloom', b'fake-executable')
        self.config = b'{"fabricated":true}\n'; self.cap = b'fake-capability'
        caproot = self.provider.parent / 'clusters'; caproot.mkdir(mode=0o700)
        publish(caproot / (digest(self.cap) + '.capability.json'), self.cap)
        expected = {HOSTS[0]: ('leader', digest(self.before), digest(self.config))}
        self.patches = [patch.object(remote, 'ROOT', self.runtime), patch.object(remote, 'HOME_DIRECTORY', self.home),
                        patch.object(remote, 'PROVIDER', self.provider), patch.object(remote, 'DEVICE', self.device),
                        patch.object(remote, 'CAPABILITY', digest(self.cap)), patch.object(remote, 'EXPECTED', expected),
                        patch.object(remote, 'PROVIDER_BINARY', digest(b'fake-executable')),
                        patch.object(remote, 'require_idle', lambda: None), patch.object(remote.subprocess, 'run', self.configure)]
        for value in self.patches: value.start()
        self.pin = None

    def tearDown(self):
        for value in reversed(self.patches): value.stop()
        self.temporary.cleanup()

    def configure(self, command, **kwargs):
        staged = Path(command[command.index('--config') + 1])
        self.assertNotEqual(staged, self.provider)
        self.assertEqual(read_private(self.provider)[0], self.before)
        publish(staged, self.after, expected=digest(self.before))
        result = dict(configurationSHA256=digest(self.config), capabilitySHA256=digest(self.cap),
                      distributedEnabled=False, readinessVerified=False)
        return SimpleNamespace(returncode=0, stdout=json.dumps(result).encode(), stderr=b'')

    def operation(self, action, pin=None):
        return remote.execute(dict(action=action, host=HOSTS[0], attempt=1,
            configuration=base64.b64encode(self.config).decode(), postimageSHA256=pin))

    def stage(self):
        receipt = self.operation('prepare'); self.pin = receipt['afterSHA256']
        self.assertEqual(read_private(self.provider)[0], self.before)

    def test_exact_prepare_install_restore_and_idempotent_restore(self):
        self.stage(); self.operation('install', self.pin)
        self.assertEqual(read_private(self.provider), (self.after, 0o600))
        self.assertTrue(self.operation('restore', self.pin)['restored'])
        self.assertEqual(read_private(self.provider), (self.before, 0o600))
        self.assertTrue(self.operation('restore', self.pin)['restored'])

    def test_wrong_preimage_refuses_without_default_mutation(self):
        publish(self.provider, b'other', expected=digest(self.before))
        with self.assertRaises(ValueError): self.operation('prepare')
        self.assertEqual(read_private(self.provider)[0], b'other')

    def test_staged_configure_failure_keeps_default_and_backup(self):
        with patch.object(remote.subprocess, 'run', return_value=SimpleNamespace(returncode=1, stdout=b'', stderr=b'fake refusal')):
            with self.assertRaises(ValueError): self.operation('prepare')
        self.assertEqual(read_private(self.provider)[0], self.before)
        self.assertEqual(read_private(self.runtime / 'configuration-transactions/configured-deadline-1/provider.before.toml')[0], self.before)
        self.assertTrue(self.operation('restore')['restored'])

    def test_restore_refuses_concurrent_edit_and_nonempty_journal(self):
        self.stage(); self.operation('install', self.pin)
        publish(self.provider, b'concurrent', expected=self.pin)
        with self.assertRaises(ValueError): self.operation('restore', self.pin)
        self.assertEqual(read_private(self.provider)[0], b'concurrent')
        publish(self.provider, self.after, expected=digest(b'concurrent'))
        publish(self.device, b'unresolved', expected=digest(b''))
        with self.assertRaises(ValueError): self.operation('restore', self.pin)
        self.assertEqual(read_private(self.device)[0], b'unresolved')
        self.assertEqual(read_private(self.provider)[0], self.after)

    def test_restore_requires_captured_postimage_pin_and_real_file(self):
        self.assertTrue(self.operation('restore')['restored'])
        self.stage(); self.operation('install', self.pin)
        with self.assertRaises(ValueError): self.operation('restore')
        with self.assertRaises(ValueError): self.operation('restore', '0' * 64)
        held = self.provider.with_name('held.toml'); self.provider.rename(held); self.provider.symlink_to(held)
        with self.assertRaises(OSError): self.operation('restore', self.pin)
        self.assertEqual(read_private(held)[0], self.after)

    def test_held_device_lock_blocks_swap(self):
        self.stage()
        with locked(self.device, require_empty=True):
            with self.assertRaises(BlockingIOError): self.operation('install', self.pin)
        self.assertEqual(read_private(self.provider)[0], self.before)

    def test_postimage_or_default_mode_change_refuses(self):
        self.stage(); self.operation('install', self.pin)
        self.provider.chmod(0o644)
        with self.assertRaises(ValueError): self.operation('restore', self.pin)
        self.provider.chmod(0o600)
        after = self.runtime / 'configuration-transactions/configured-deadline-1/provider.after.toml'
        publish(after, b'tampered', expected=self.pin)
        with self.assertRaises(ValueError): self.operation('restore', self.pin)
        self.assertEqual(read_private(self.provider)[0], self.after)


class RecoveryPackagingTests(unittest.TestCase):
    def test_retained_prepare_receipt_is_verified_per_host(self):
        with tempfile.TemporaryDirectory(prefix='.recovery-check-', dir=Path(__file__).resolve().parent) as name:
            root = Path(name)
            for host in HOSTS:
                raw = json.dumps(dict(memberID=host, afterSHA256='a' * 64)).encode()
                publish(root / (host + '.prepare.stdout.json'), raw)
                publish(root / (host + '.prepare.receipt.json'), json.dumps(dict(exitCode=0,
                    stdoutSHA256=hashlib.sha256(raw).hexdigest())).encode())
            pins, errors = recovery_pins(root)
            self.assertEqual(pins, {host: 'a' * 64 for host in HOSTS}); self.assertFalse(errors)
            path = root / (HOSTS[0] + '.prepare.stdout.json')
            publish(path, b'{}', expected=digest(read_private(path)[0]))
            pins, errors = recovery_pins(root)
            self.assertNotIn(HOSTS[0], pins); self.assertIn(HOSTS[0], errors)
            self.assertEqual(pins[HOSTS[1]], 'a' * 64)

    def test_bundled_python39_remote_rejects_before_any_file_access(self):
        result = subprocess.run(['/usr/bin/python3', '-B', '-c', bundled_remote()], input=b'{}', capture_output=True, timeout=5)
        self.assertEqual(result.returncode, 1)
        self.assertIn('Invalid fixed configuration transaction', json.loads(result.stdout)['error'])
        self.assertEqual(result.stderr, b'')


if __name__ == '__main__': unittest.main()
