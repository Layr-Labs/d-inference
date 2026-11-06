"""Composite synthetic evidence, with native/process/network launch prohibited."""
import contextlib
import copy
import io
import json
from pathlib import Path
import socket
import tempfile
import unittest
from unittest.mock import patch

from audit_short_execution_binding import audit_packet, main
from binding_common import canonical, sha
from binding_test_support import PacketFixture, TOKENS, raw


class BindingPipelineTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.folder = Path(temporary.name)
        self.fixture = PacketFixture(self.folder)
        for target in ('subprocess.Popen', 'subprocess.run'):
            block = patch(target, side_effect=AssertionError('No process launch permitted'))
            block.start();self.addCleanup(block.stop)
        block = patch.object(socket, 'socket', side_effect=AssertionError('No network permitted'))
        block.start();self.addCleanup(block.stop)

    def check(self, fixture=None):
        return audit_packet((fixture or self.fixture).path)

    def reject_parent_changes(self, changes):
        original = copy.deepcopy(self.fixture.parent)
        for index, change in enumerate(changes):
            with self.subTest(index=index):
                self.fixture.parent = copy.deepcopy(original)
                change(self.fixture.parent)
                self.fixture.publish()
                with self.assertRaises(ValueError):
                    self.check()
        self.fixture.parent = original
        self.fixture.publish()

    def test_both_models_and_fresh_reused_paths(self):
        for profile in ('registered_qwen35_9b', 'registered_qwen38_27b'):
            for reused in (False, True):
                with self.subTest(profile=profile, reused=reused), tempfile.TemporaryDirectory() as folder:
                    fixture = PacketFixture(folder, profile, reused)
                    result = self.check(fixture)
                    self.assertTrue(result['passed'])
                    self.assertEqual(result['profileDefinition']['registeredProfile'], profile)
                    self.assertEqual(result['profileDefinition']['naxAvailability'], 'unknown')
                    self.assertEqual(result['retainedMemberCounts'], dict(source=16, bundle=4, private=6))
                    self.assertEqual(result['freshNumericalReplay']['independentlyComparedNativeLogitPairs'], 2)
                    for flag in ('hardwareSpecificQualification', 'historicalNativeExecutionIndependentlyVerified',
                                 'sourceToBinaryBuildVerified', 'loadedMetallibIndependentlyVerified',
                                 'completeProcessEnvironmentVerified', 'hardwareIdentityAttested',
                                 'physicalTwoMachineExecution', 'executionAdmission', 'throughputQualification'):
                        self.assertFalse(result[flag])
                    self.assertEqual(result['parentObservations']['ownedSamples'], 0)
                    self.assertIsNone(result['parentObservations']['measuredWholeProcessPeakBytes'])

    def test_relocation_and_pid_change_preserve_profile_but_change_evidence(self):
        left = self.check()
        with tempfile.TemporaryDirectory() as folder:
            other = PacketFixture(folder, run_root='/invented/another-run', pid=92)
            other.source['repository'] = '/invented/another-repository'
            other.parent['runtime'] = '/invented/another-repository/experiments/cluster/runtime'
            other.refresh_manifests()
            right = self.check(other)
        self.assertEqual(left['recordedRuntimeProfileSHA256'], right['recordedRuntimeProfileSHA256'])
        self.assertNotEqual(left['executionEvidenceSHA256'], right['executionEvidenceSHA256'])

    def test_coherently_changed_architecture_changes_profile_without_qualification(self):
        previous = self.check()
        for row in (self.fixture.rows[0]['runtime'], self.fixture.rows[1]['pair']['runtime']):
            row['deviceArchitecture'] = 'another-fabricated-architecture'
        self.fixture.refresh_native()
        current = self.check()
        self.assertNotEqual(previous['recordedRuntimeProfileSHA256'], current['recordedRuntimeProfileSHA256'])
        self.assertFalse(current['hardwareIdentityAttested'])

    def test_returned_receipt_cannot_mutate_frozen_policy_or_oracle_pins(self):
        previous=self.check()
        original=copy.deepcopy(previous)
        previous['profileDefinition']['arithmeticEnvironment']['MLX_METAL_FAST_SYNCH']='changed'
        previous['bindings']['numericalOracleSourceSHA256']['audit_short_parity.py']='0'*64
        previous['bindings']['parentPrivateSourceSHA256']['run_short_parity.py']='0'*64
        self.assertEqual(self.check(),original)

    def test_failed_parent_stale_result_and_changed_identity_refused(self):
        self.reject_parent_changes([
            lambda p:p.update(status='failed'), lambda p:p.update(nativeReaped=False),
            lambda p:p.update(nativeExitCode=True), lambda p:p.update(nativePID=True),
            lambda p:p.update(primaryFailure='failure'), lambda p:p.update(cleanupErrors=['leftover']),
            lambda p:p.update(postRunErrors=[{}]), lambda p:p.update(ownedProcessGroupAfter=[{}]),
            lambda p:p.update(expectedNativeSHA256='0'*64), lambda p:p.update(baselineEvidenceSHA256='0'*64),
            lambda p:p.update(extra=True), lambda p:p['privateSourceSHA256'].update(run_short_parity_py='0'*64),
            lambda p:p['arithmeticEnvironment'].update(MLX_METAL_GPU_ARCH='override'),
            lambda p:p['command'].__setitem__(-1,'121'), lambda p:p['command'].__setitem__(8,'/invented/another-prompt'),
            lambda p:p.update(bundleCopiedForThisRun=False), lambda p:p.update(sourceFileCount=True),
        ])

    def test_source_impossible_parent_directory_and_observations_refused(self):
        def inside(p):
            root='/invented/repository/inside'
            p['command'][0]=root+'/bundle/cluster-inference'
            p['command'][8]=root+'/prompt.json';p['command'][12]=root+'/teacher.json'
        def owned(p, index):
            p['memorySamples'][index].update(nativePID=p['nativePID'], nativePGID=p['nativePID'],
                nativeRSSBytes=1024, nativeCommand=' '.join(p['command']))
        self.reject_parent_changes([
            inside, lambda p:owned(p,1), lambda p:p['powerObservations'].pop(),
            lambda p:p['memorySamples'][1].update(monotonicSeconds=-1),
            lambda p:p['memorySamples'][0].update(reportedSwapBytes='1'),
            lambda p:p['memorySamples'][0].update(actualFreeBytes=1),
            lambda p:p['powerObservations'][0]['admission'].update(batteryFloorApplied=True),
            lambda p:p['memorySamples'][0].update(terminalExitCodeObservedAfterSample=0),
        ])

    def test_optional_paths_and_valid_terminal_race_scope(self):
        p=self.fixture.parent
        p['promptFile']='/invented/original/../prompt.json'
        sample=self.fixture.sample(2)
        sample.update(nativePID=p['nativePID'],nativePGID=p['nativePID'],nativeRSSBytes=0,
                      nativeCommand='<defunct>',terminalExitCodeObservedAfterSample=0,
                      nativeObservationClassification='owned_terminal_during_observation',defunctSampleIsLiveRSS=False)
        p['memorySamples'].insert(2,sample);p['memorySamples'][-1]['monotonicSeconds']=3.0
        p['powerObservations'].insert(2,self.fixture.power());self.fixture.publish()
        result=self.check()
        self.assertEqual(result['parentObservations']['terminalSamples'],1)
        self.assertFalse(result['parentObservations']['liveRSSObservedByAuditor'])
        p['memorySamples'].insert(2,copy.deepcopy(sample));p['powerObservations'].insert(2,self.fixture.power())
        self.fixture.publish()
        with self.assertRaises(ValueError):self.check()

    def test_runtime_pair_and_missing_executable_are_not_complete_bindings(self):
        for change in (lambda r:r[1]['pair']['runtime'].update(deviceArchitecture='different'),
                       lambda r:r[0]['runtime'].update(processID=74),
                       lambda r:[(v.pop('executablePath'),v.pop('executableName')) for v in (r[0]['runtime'],r[1]['pair']['runtime'])]):
            original=copy.deepcopy(self.fixture.rows)
            change(self.fixture.rows);self.fixture.refresh_native()
            with self.assertRaises(ValueError):self.check()
            self.fixture.rows=original

    def test_reused_reference_substitutions_refused(self):
        with tempfile.TemporaryDirectory() as folder:
            fixture=PacketFixture(folder,reused=True)
            fixture.parent['bundleReference']['requestedPath']='/invented/original/../requested-bundle'
            fixture.publish()
            self.assertTrue(self.check(fixture)['passed'])
            original=copy.deepcopy(fixture.parent)
            for change in (lambda p:p['bundleReference'].update(verifiedFileCount=3),
                           lambda p:p['bundleReference'].update(resolvedPath='/invented/wrong'),
                           lambda p:p['bundleReference']['runtimeFilesSHA256'].update(**{'artifacts.py':'0'*64}),
                           lambda p:p.update(bundleReferenceHelperSHA256='0'*64)):
                fixture.parent=copy.deepcopy(original);change(fixture.parent);fixture.publish()
                with self.assertRaises(ValueError):self.check(fixture)

    def test_complete_numerical_result_is_replayed_not_trusted(self):
        report=json.loads(self.fixture.core['numerical'])
        report['fullVocabularyLogitByteParityEstablished']=False
        self.fixture.core['numerical']=canonical(report);self.fixture.publish()
        with self.assertRaises(ValueError):self.check()
        # Keep an apparently passed receipt and coherent parent hashes while
        # changing a native logit row. The fresh numerical oracle must refuse it.
        report['fullVocabularyLogitByteParityEstablished']=True
        self.fixture.rows[1]['pair']['comparison']['frames'][1]['logits']['values'][0]=1.0
        self.fixture.core['stdout']=raw(self.fixture.rows)
        self.fixture.parent.update(self.fixture.contract.validate_result(self.fixture.core['stdout'],self.fixture.profile,TOKENS))
        data=self.fixture.core['stdout']
        self.fixture.parent['stdout.jsonl']=dict(sizeBytes=len(data),sha256=sha(data),hashOmittedBecauseOversized=False)
        report.update(stdoutSHA256=sha(data),stdoutBytes=len(data))
        self.fixture.core['numerical']=canonical(report);self.fixture.publish()
        with self.assertRaises(ValueError):self.check()

    def test_resealed_unsupported_source_and_changed_members_refused(self):
        row=next(r for r in self.fixture.source['files'] if r['path'].endswith('QwenDenseStageLoadResources.swift'))
        ref=next(r for r in self.fixture.source_refs if r['member']==row['path'])
        data=b'changed unsupported runtime observation source'
        (self.folder/ref['path']).write_bytes(data);row.update(size_bytes=len(data),sha256=sha(data))
        self.fixture.refresh_manifests()
        with self.assertRaisesRegex(ValueError,'Unsupported native'):self.check()

    def test_cli_publishes_new_private_success_or_failure_and_never_overwrites(self):
        target=self.folder/'result.json'
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(main([str(self.fixture.path),'--output',str(target)]),0)
        self.assertEqual(target.stat().st_mode & 0o777,0o600)
        self.assertTrue(json.loads(target.read_bytes())['passed'])
        with self.assertRaises(ValueError):main([str(self.fixture.path),'--output',str(target)])
        self.fixture.parent['nativeReaped']=False;self.fixture.publish()
        failure=self.folder/'failed.json'
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(main([str(self.fixture.path),'--output',str(failure)]),1)
        value=json.loads(failure.read_bytes());self.assertFalse(value['passed']);self.assertFalse(value['executionAdmission'])


if __name__=='__main__':unittest.main()
