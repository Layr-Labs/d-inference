"""CPU-only output-contract and actual process supervision checks; no MLX."""
import copy
import json
from pathlib import Path
import sys
import tempfile
import time
import unittest

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent/'package'))
from target_contract import BASE_CASES, FAILURE_CASES, validate_result
from target_processes import parse_processes
from target_supervision import serve
from worker_contract import WorkerSpec


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
                result=serve(spec, Path(folder), time.monotonic(), lambda _:None, Pins(), lambda:{})
                receipt=json.loads((Path(folder)/'terminal.json').read_text())
                self.assertEqual(result, 0 if scenario=='success' else 1)
                self.assertTrue(receipt['nativeLeaderReaped'])
                self.assertTrue(receipt['ownedGroupsAbsent'])
                self.assertFalse(receipt['registeredCheckpointExecution'])
                self.assertFalse(receipt['bilateralVerification'])
                self.assertEqual(receipt['modelTrunkExecutionObserved'], scenario!='incomplete')
                if scenario=='success': self.assertTrue(receipt['outputComplete'])


if __name__=='__main__': unittest.main()
