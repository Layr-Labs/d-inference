import copy
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

from binding_common import canonical
from mtp_clock import sample_clock
from mtp_contract import expected_identity
from mtp_controls import read_controls
from mtp_inputs import BUNDLE, METALLIB, NATIVE, SOURCE, Pins, write_json
from mtp_journal import observe, require_empty
from run_mtp_load import serve
from selected_read_accounting import CONSTANTS
from worker_contract import WorkerSpec, workers

ROOT = Path(__file__).resolve().parent
GIB = 1024**3


def accounting(tensors):
    sizes = [x['byteCount'] for x in tensors]
    padded = [((size+16383)//16384)*16384 for size in sizes]
    return dict(CONSTANTS, selectedBytes=sum(sizes), requestedReadBytes=sum(padded),
        returnedReadBytes=sum(padded), paddingReadBytes=sum(padded)-sum(sizes),
        preadCalls=sum((n+8*1024**2-1)//(8*1024**2) for n in padded), interruptedCalls=0,
        shortEOFReads=0, largestScratchRequestBytes=8*1024**2, largestScratchAllocationBytes=8*1024**2)


def os_value(ordinal):
    return dict(startedNanoseconds=1000+ordinal*100, completedNanoseconds=1050+ordinal*100,
        timestampUTC='2026-09-15T00:00:00Z', physicalMemoryBytes=48*GIB, pageSizeBytes=16384,
        kernelFreePages=20*GIB//16384+10, freePages=20*GIB//16384, inactivePages=10,
        speculativePages=10, actualFreeBytes=20*GIB, estimatedReclaimableBytes=20*GIB+20*16384,
        pressureLevel=1, swapUsedBytes=0)


def mem(phase, active, peak):
    return dict(phase=phase, activeMLXBytes=active, cachedMLXBytes=0, peakMLXBytesSinceProcessStart=peak)


def fixture(run):
    control = read_controls(ROOT, Pins())
    job = dict(schema='private_mtp_selected_load_job_v1', run_id='8e1b2d57-d0de-4c70-af6e-9c590d91acbc',
        deployment=str(run/'bundle'), model_dir=str(run/'model'), run_dir=str(run), bundle_sha256=BUNDLE,
        native_sha256=NATIVE, metallib_sha256=METALLIB, source_manifest_sha256=SOURCE,
        native_seconds=300, parent_seconds=315)
    expected = expected_identity(job, 900_000_000_000, control)
    admitted = dict(expected, initialResources=os_value(0))
    target = dict(control['target'], selectedPayloadReadAccounting=accounting(control['target']['activeTensors']))
    extras = control['additional']
    placement = dict(targetPlanSHA256=target['planSHA256'], ownerRank=1, embeddingSourceOwnerRank=0,
        embeddingIsExplicitReplica=True, generationEnabled=False,
        head=sorted([x for x in extras if x['name'].startswith('mtp.')], key=lambda x:x['name']),
        embedding=sorted([x for x in extras if not x['name'].startswith('mtp.')], key=lambda x:x['name']),
        headBytes=136881152, replicatedEmbeddingBytes=572129280, additionalTensorBytes=709010432)
    mtp = dict(placement=placement, targetLoadReceiptSHA256=hashlib.sha256(canonical(target)).hexdigest(),
        loadedTensorBytes=709010432, allocatorReservedTensorBytes=709010432,
        sourceReadAccounting=accounting(extras), independentlyOwnedAdditionalBuffers=True,
        sharesTargetFinalNormAndOutputHead=True, targetResidualEmbeddingUnchanged=True,
        generationEnabled=False, requestHistoryAllocated=False)
    report = dict(schema=expected['schema'], type='report', completed=True, admission=admitted,
        payload=dict(targetLoad=target, mtpLoad=mtp, loadedResources=os_value(1),
                     loadedMemory=mem('selected_mtp_loaded', 5*GIB, 6*GIB)),
        initialMemory=mem('before_selected_mtp_load', 0, 0),
        releasedMemory=mem('selected_mtp_released', 0, 6*GIB), releasedResources=os_value(2),
        runtime=dict(mainBundleName='bundle', mainBundlePath=str(run/'bundle'), processID=1,
            operatingSystemVersion='Fabricated CPU fixture', deviceArchitecture='fabricated',
            deviceMemoryBytes=48*GIB, maximumBufferBytes=30*GIB, recommendedWorkingSetBytes=32*GIB,
            binaryOrBundleHashVerifiedByNative=False, providerEligibilityEstablished=False,
            recommendedWorkingSetUsedForAdmission=False))
    for key in ('targetOwnerReleased', 'assistantOwnerReleased', 'verifiedFileOwnerReleased',
                'cacheClearCompleted', 'targetLoadReceiptPreserved', 'additionalBuffersCheckedAtMaterialization',
                'parentProcessFencingIndependentlyRequired'):
        report[key] = True
    for key in ('collectiveInitialized','bilateralAdmissionPerformed','forwardExecuted','requestStateCreated',
                'generationEnabled','tensorValuesIndependentlyCompared','numericalParityEstablished',
                'pairwiseBufferAddressesIndependentlyCompared','providerEligibilityEstablished','throughputMeasurementValid'):
        report[key] = False
    return job, control, expected, [admitted, report]


class SupervisorChecks(unittest.TestCase):
    def execute(self, mode='success', sticky=False, changed_input=False):
        with tempfile.TemporaryDirectory() as name:
            run = Path(name)
            job, control, expected, records = fixture(run)
            write_json(run/'fabricated-records.json', records)
            spec = workers([WorkerSpec((sys.executable, str(ROOT/'fabricated_mtp.py'),
                str(run/'fabricated-records.json'), mode), {'PATH':'/usr/bin:/bin'}, 'solo', None)])[0]
            def journal():
                if sticky:
                    raise ValueError('fabricated sticky journal')
            pins = Pins()
            if changed_input:
                pinned = run/'pinned-input'
                pinned.write_bytes(b'before')
                pins.read(pinned, 64)
                pinned.write_bytes(b'changed')
            code = serve(job, spec, control, expected, run, lambda phase:None, pins, journal,
                         timeout=2 if mode == 'hang' else 5)
            terminal = json.loads((run/'terminal.json').read_text())
            self.assertTrue(terminal['nativeLeaderReaped'])
            self.assertTrue(terminal['ownedGroupFenceComplete'])
            self.assertEqual(terminal['nativeExitCodes'][0] is not None, True)
            return code, terminal

    def test_complete(self):
        code, value = self.execute()
        self.assertEqual(code, 0)
        self.assertEqual(value['recordsAccepted'], 2)
        self.assertTrue(value['journalEmptyAfterExit'])
        self.assertTrue(value['targetSemanticReceiptMatched'])
        self.assertFalse(value['independentNumericalComparisonPerformed'])
        self.assertEqual(value['owner']['remainingGroupWatchdogSeconds'], 4)

    def test_metadata_and_retirement_refusal(self):
        for mode in ('bad-target','bad-extra','bad-target-hash','bad-read-accounting',
                     'bad-free-arithmetic','nonempty-cache','missing-retirement'):
            with self.subTest(mode=mode):
                code, value = self.execute(mode)
                self.assertEqual(code, 1)
                self.assertEqual(value['recordsAccepted'], 1)

    def test_terminal_failures(self):
        for mode in ('extra-line','nonzero','hang'):
            with self.subTest(mode=mode):
                code, value = self.execute(mode)
                self.assertEqual(code, 1)
                self.assertEqual(value['status'], 'failed')

    def test_sticky_journal_fails_after_valid_records(self):
        code, value = self.execute(sticky=True)
        self.assertEqual(code, 1)
        self.assertEqual(value['recordsAccepted'], 2)
        self.assertEqual(value['postflightErrors'][0]['operation'], 'journal_postflight')
        self.assertFalse(value['journalEmptyAfterExit'])

    def test_changed_input_fails_after_valid_records(self):
        code, value = self.execute(changed_input=True)
        self.assertEqual(code, 1)
        self.assertEqual(value['recordsAccepted'], 2)
        self.assertFalse(value['sourceInputsUnchanged'])
        self.assertEqual(value['postflightErrors'][0]['operation'], 'source_input_recheck')

    def test_clock_owned_success_and_refusal(self):
        for output, valid in [('1234567890', True), ('00123', False), ('-1', False), ('123\\n456', False)]:
            with self.subTest(output=output), tempfile.TemporaryDirectory() as name:
                run = Path(name)
                spec = workers([WorkerSpec((sys.executable, '-c', 'print("%s")'%output),
                    {'PATH':'/usr/bin:/bin'}, 'solo', None)])[0]
                if valid:
                    self.assertEqual(sample_clock(spec, run, lambda phase:None), 1234567890)
                else:
                    with self.assertRaises(Exception):
                        sample_clock(spec, run, lambda phase:None)
                record = json.loads((run/'clock-terminal.json').read_text())
                self.assertTrue(record['reaped'] and record['groupFenced'])

    def test_journal_is_read_only_and_sticky(self):
        with tempfile.TemporaryDirectory() as name:
            directory = Path(name).resolve(); path = directory/'native-device.lease'
            path.write_bytes(b''); path.chmod(0o600)
            before = observe(directory); require_empty(before)
            path.write_bytes(b'owned')
            value = observe(directory)
            self.assertEqual(path.read_bytes(), b'owned')
            with self.assertRaises(ValueError): require_empty(value, before)
            path.rename(directory/'retired.lease'); path.write_bytes(b''); path.chmod(0o600)
            after = observe(directory)
            with self.assertRaises(ValueError): require_empty(after, before)

    def test_journal_link_and_live_lock_refused(self):
        with tempfile.TemporaryDirectory() as name:
            directory = Path(name).resolve(); path = directory/'native-device.lease'
            path.write_bytes(b''); path.chmod(0o600)
            descriptor = os.open(path, os.O_RDONLY)
            try:
                fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
                with self.assertRaises(BlockingIOError): observe(directory)
            finally: os.close(descriptor)
            path.unlink(); path.symlink_to(directory/'absent')
            with self.assertRaises(OSError): observe(directory)

    def test_isolated_transitive_import_closure(self):
        with tempfile.TemporaryDirectory() as name:
            package = Path(name)
            for path in ROOT.glob('*.py'):
                shutil.copy2(path, package/path.name)
            shutil.copytree(ROOT/'stage_checks', package/'stage_checks', ignore=shutil.ignore_patterns('__pycache__'))
            shutil.copytree(ROOT/'inputs', package/'inputs')
            command = [sys.executable, '-I', '-c',
                'import sys;sys.dont_write_bytecode=True;sys.path.insert(0,sys.argv[1]);'
                'import run_mtp_load;from pathlib import Path;from mtp_controls import read_controls;'
                'from mtp_inputs import Pins;read_controls(Path(sys.argv[1]),Pins());print("closure imported")', str(package)]
            good = subprocess.run(command, capture_output=True, timeout=10)
            self.assertEqual(good.returncode, 0, good.stderr)
            self.assertEqual(good.stdout, b'closure imported\n')
            (package/'inputs/arithmetic.json').rename(package/'inputs/arithmetic.saved')
            missing_resource = subprocess.run(command, capture_output=True, timeout=10)
            self.assertNotEqual(missing_resource.returncode, 0)
            self.assertIn(b'arithmetic.json', missing_resource.stderr)
            (package/'inputs/arithmetic.saved').rename(package/'inputs/arithmetic.json')
            (package/'stage_checks/common.py').unlink()
            bad = subprocess.run(command, capture_output=True, timeout=10)
            self.assertNotEqual(bad.returncode, 0)
            self.assertIn(b'stage_checks.common', bad.stderr)


if __name__ == '__main__':
    unittest.main()
