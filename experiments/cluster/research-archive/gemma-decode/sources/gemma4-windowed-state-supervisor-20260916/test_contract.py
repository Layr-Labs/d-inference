"""CPU-only output-contract and actual process supervision checks; no MLX."""
import copy
import json
from pathlib import Path
import sys
import tempfile
import time
import unittest
from unittest.mock import patch
from types import SimpleNamespace
import threading
import signal

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent/'package'))
from session_result import BASE_CASES, FAILURE_CASES, validate_result
from target_processes import parse_processes
from target_supervision import serve
from worker_contract import WorkerSpec
from worker_processes import PipeWorkers


def example(eos=True):
    return dict(fixture='fabricated-full-source-two-real-stages',
        passed=BASE_CASES + (['actual-progressive-eos'] if eos else []) + FAILURE_CASES,
        maximumLogitDifference=0.0,
        stateComparison='exact-named-state-hashes-after-reconcile-and-next-decode',
        seedTokenID=1, ordinaryTargetChosenDraftTokenID=2 if eos else 1,
        eosAfterSeedExercised=eos, sourceTensorCount=100, sourceTensorBytes=4096,
        sourcePayloadSHA256='a'*64, stageActiveTensorCounts=[50,50],
        sharedSessionTransactionExecuted=True, registeredProfileExecuted=False,
        mtpAssistantProposalExecuted=False, bilateralWireVerification=False,
        providerEligibilityEstablished=False,
        resourceLedger=dict(maximumTokens=9, chunkTokens=2, simultaneousPairs=2,
            perPairLogicalStateAndBoundaryBytes=108808, roundedStateAndBoundaryBytes=217616,
            fusionBytes=0, comparisonNativeBytes=2048, comparisonHostBytes=1024,
            transactionNativeBytes=[1032,2056], transactionHostBytes=[256,256], wholeProcessBound=False))


def raw(value):
    return json.dumps(value, separators=(',', ':')).encode()


class ContractTests(unittest.TestCase):
    def test_both_actual_eos_outcomes(self):
        for eos in (True, False): self.assertEqual(validate_result(raw(example(eos))), example(eos))

    def test_wrong_claims_or_incomplete_cases_refused(self):
        edits = [
            ('passed', BASE_CASES), ('passed', example()['passed'][::-1]),
            ('eosAfterSeedExercised', False), ('seedTokenID', True),
            ('sourceTensorCount', True), ('stageActiveTensorCounts', [50,49]),
            ('maximumLogitDifference', 0.0001), ('maximumLogitDifference', float('nan')),
            ('maximumLogitDifference', -1), ('maximumLogitDifference', True),
            ('sharedSessionTransactionExecuted', False), ('registeredProfileExecuted', True),
            ('mtpAssistantProposalExecuted', True), ('bilateralWireVerification', True),
            ('providerEligibilityEstablished', True), ('sourcePayloadSHA256', 'unknown'),
            ('sourceTensorBytes', 64*1024**2+1), ('ordinaryTargetChosenDraftTokenID', 128)]
        for key, value in edits:
            row=example(); row[key]=value
            with self.subTest(key=key, value=value), self.assertRaises(ValueError): validate_result(raw(row))
        for key, value in [('maximumTokens', 7), ('comparisonNativeBytes', 1024),
                ('roundedStateAndBoundaryBytes', 108808), ('wholeProcessBound', True),
                ('transactionHostBytes', [256]), ('fusionBytes', 1), ('comparisonHostBytes', 1023)]:
            row=example(); row['resourceLedger'][key]=value
            with self.subTest(ledger=key), self.assertRaises(ValueError): validate_result(raw(row))

    def test_strict_shape_and_json(self):
        value=raw(example())
        for bad in (value[:-1]+b',"fixture":"duplicate"}', b'x'*16385,
                raw(dict(example(), surprise=True)), raw({k:v for k,v in example().items() if k!='sourceTensorCount'})):
            with self.assertRaises(ValueError): validate_result(bad)

    def test_native_process_inventory(self):
        result=parse_processes(b'42 501 /tmp/TargetVerificationSessionCheck\n43 501 /usr/bin/python3\n')
        self.assertEqual([x['pid'] for x in result['prohibited']], [42])

    def test_actual_cpu_child_success_and_failure_cleanup(self):
        class Pins:
            def recheck(self): pass
        for scenario in ('success','nonzero','incomplete'):
            with self.subTest(scenario=scenario), tempfile.TemporaryDirectory() as folder:
                output=raw(example() if scenario!='incomplete' else dict(example(), passed=[]))
                code='import sys; sys.stdout.buffer.write('+repr(output+b'\n')+'); sys.stdout.flush(); sys.exit('+('7' if scenario=='nonzero' else '0')+')'
                spec=WorkerSpec((sys.executable,'-c',code), {'PATH':'/usr/bin:/bin'}, 'solo', None)
                result=serve(spec, Path(folder), time.monotonic(), lambda _:None, Pins(), lambda:{}, 'session')
                receipt=json.loads((Path(folder)/'terminal.json').read_text())
                self.assertEqual(result, 0 if scenario=='success' else 1)
                self.assertTrue(receipt['nativeLeaderReaped'])
                self.assertTrue(receipt['ownedGroupsAbsent'])
                self.assertFalse(receipt['registeredCheckpointExecution'])
                self.assertFalse(receipt['bilateralVerification'])
                self.assertEqual(receipt['modelTrunkExecutionObserved'], scenario!='incomplete')
                if scenario=='success': self.assertTrue(receipt['outputComplete'])

    def test_reaped_leader_never_authorizes_destructive_group_signal(self):
        pipes=PipeWorkers((), '/unused', 1, lambda _:None)
        child=SimpleNamespace(pid=12345,returncode=7)
        pipes.children=[child]
        try:
            with patch('worker_processes.os.killpg') as signal_group:
                pipes._kill_groups()
                self.assertEqual(signal_group.call_args_list, [unittest.mock.call(12345,0)])
                self.assertTrue(pipes.cleanup_errors)
                self.assertNotIn(12345,pipes._fenced_groups)
            with patch('worker_processes.os.killpg', side_effect=ProcessLookupError):
                pipes._kill_groups()
                self.assertIn(12345,pipes._fenced_groups)
        finally: pipes.selector.close()

    def test_reap_and_watchdog_signal_share_ownership_lock(self):
        pipes=PipeWorkers((), '/unused', 1, lambda _:None)
        entered=threading.Event(); release=threading.Event(); attempted=threading.Event()
        class Child:
            pid=12345
            returncode=None
            def wait(self, timeout):
                entered.set()
                if not release.wait(2): raise RuntimeError('Fixture release missing')
                self.returncode=7
                return 7
        child=Child();pipes.children=[child]
        def expire(): attempted.set(); pipes._kill_groups()
        waiter=threading.Thread(target=lambda:pipes._wait(child))
        killer=threading.Thread(target=expire)
        try:
            with patch('worker_processes.os.killpg') as signal_group:
                waiter.start();self.assertTrue(entered.wait(2));killer.start();self.assertTrue(attempted.wait(2))
                self.assertFalse(signal_group.called)
                release.set();waiter.join(2);killer.join(2)
                self.assertFalse(waiter.is_alive() or killer.is_alive())
                self.assertEqual(signal_group.call_args_list,[unittest.mock.call(12345,0)])
        finally:
            release.set()
            if waiter.ident is not None:waiter.join(2)
            if killer.ident is not None:killer.join(2)
            pipes.selector.close()


if __name__=='__main__': unittest.main()
