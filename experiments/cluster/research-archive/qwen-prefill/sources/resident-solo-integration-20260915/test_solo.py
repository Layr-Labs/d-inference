"""CPU tests: fabricated reports/processes plus the pinned saved reference, no model execution."""
import copy
import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from fabricated_solo import resources, ready, result, released, stopped, envelope
from run_solo import RawEvents, four_requests, make_cohort, main
from solo_identity import SoloValidator
from solo_provenance import PinnedFiles, inherited
from solo_reference import Reference, timing
from solo_resources import GIB, ResourceGate, native_resources, sample_local, validate_local
from stage_checks.common import digest
from worker_contract import WorkerSpec, open_command, run_command

HERE=Path(__file__).parent


class SoloChecks(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.reference=Reference()

    def controls(self):
        declared,requests=four_requests('diagnostic:solo')
        opened=open_command('diagnostic:solo',declared)
        return opened,[run_command(opened,i,r) for i,r in enumerate(requests)],declared,requests

    def validator(self):
        return SoloValidator(self.reference,Path('/tmp/bundle'),lambda:123,lambda event:'a'*64)

    def test_reference_pin_and_reconstructed_numerics(self):
        self.assertEqual(self.reference.summary['reconstructedReferenceBF16Bytes'],496640)
        self.assertEqual(self.reference.token,271)
        self.reference.recheck()
        with tempfile.TemporaryDirectory() as directory:
            for name in self.reference.saved:
                (Path(directory)/name).write_bytes((self.reference.directory/name).read_bytes())
            path=Path(directory)/'prompt.json';path.write_bytes(path.read_bytes()+b' ')
            with self.assertRaisesRegex(ValueError,'reference pin'):Reference(directory)

    def test_exact_native_shaped_success_and_detached_measurements(self):
        opened,commands,_,_=self.controls();v=self.validator();spec=WorkerSpec(('native',),{},'solo',None)
        v.identity(spec,envelope('ready',ready(self.reference,123,'/tmp/bundle'),opened['cohort_id']),opened)
        for command in commands:
            event=envelope('result',result(self.reference,command),opened['cohort_id'])
            v.identity(spec,event,command)
            measured=v.numerical(command,[event])
            measured['elapsed_ns']=0
        v.identity(spec,envelope('released',released(),opened['cohort_id']),commands[-1])
        v.identity(spec,envelope('stopped',stopped(),opened['cohort_id']),dict(sequence=5))
        self.assertTrue(v.stopped);self.assertEqual(v.ordinal,4)
        self.assertTrue(all(row['elapsed_ns']==100 for row in v.results))
        self.assertTrue(all(not row['candidateNativeBytesIndependentlyReconstructed'] for row in v.results))

    def test_numeric_source_history_and_state_mutations(self):
        _,commands,_,_=self.controls();base=result(self.reference,commands[0])['execution']
        changes=[lambda r:r['finalLogits'].update(logicalBytesSHA256='0'*64),
            lambda r:r['finalState']['entries'][0].update(sha256='0'*64),
            lambda r:r['selection'].update(tokenID=272),
            lambda r:r['sourceLoad'].update(loadedTensorBytes=1),
            lambda r:r['request']['promptTokenIDs'].__setitem__(0,1),
            lambda r:r['commits'][3].update(committedTokens=1),
            lambda r:r.update(allRequestStateRetired=False),
            lambda r:r.update(fullVocabularyValuesExported=True)]
        for change in changes:
            row=copy.deepcopy(base);change(row)
            with self.subTest(change=change),self.assertRaises(ValueError):self.reference.validate(row,commands[0]['epoch'])

    def test_timing_boundaries_boolean_and_rate(self):
        _,commands,_,_=self.controls();base=result(self.reference,commands[0])['execution']['timing']
        for key,value in [('elapsedNanoseconds',True),('elapsedNanoseconds',0),('elapsedNanoseconds',101),
            ('stopUptimeNanoseconds',2**64),('promptTokensPerFirstTokenSecond',float('nan')),
            ('promptTokensPerFirstTokenSecond',8192e9/101),('includesFreshRequestState',False),
            ('includesTransport',True),('postStopThroughRequestCloseNanoseconds',-1)]:
            row=copy.deepcopy(base);row[key]=value
            with self.subTest(key=key),self.assertRaises(ValueError):timing(row)

    def test_ready_pid_bundle_arithmetic_and_flags(self):
        opened,_,_,_=self.controls();spec=WorkerSpec(('native',),{},'solo',None)
        for change in [lambda r:r['runtime'].update(processID=124),
            lambda r:r['runtime'].update(mainBundlePath='/tmp/elsewhere'),
            lambda r:r['runtime'].pop('executablePath'),
            lambda r:r['execution'].update(arithmeticEnvironmentSHA256='0'*64),
            lambda r:r['execution'].update(verifiedModelLoaded=False),
            lambda r:r['execution'].update(warmupCount=0)]:
            row=ready(self.reference,123,'/tmp/bundle');change(row)
            with self.subTest(change=change),self.assertRaises(ValueError):self.validator().identity(spec,envelope('ready',row,opened['cohort_id']),opened)

    def test_result_request_binding_and_retirement_order(self):
        opened,commands,_,_=self.controls();spec=WorkerSpec(('native',),{},'solo',None)
        for change in [lambda r:r['step'].update(excludedWarmup=False),
            lambda r:r['step'].update(recordedRequestFingerprint='0'*64),
            lambda r:r['resourcesBeforeRequest']['os'].update(startedNanoseconds=1100,completedNanoseconds=1110),
            lambda r:r['resourcesAfterRequest']['os'].update(startedNanoseconds=1100,completedNanoseconds=1110)]:
            v=self.validator();v.identity(spec,envelope('ready',ready(self.reference,123,'/tmp/bundle'),opened['cohort_id']),opened)
            row=result(self.reference,commands[0]);change(row)
            with self.subTest(change=change),self.assertRaises(ValueError):v.identity(spec,envelope('result',row,opened['cohort_id']),commands[0])

    def test_native_resource_accounting_and_floor(self):
        for change in [lambda r:r['os'].update(swapUsedBytes=1),lambda r:r.update(powerSource='battery'),
            lambda r:r.update(thermalState=2),lambda r:r.update(wholeProcessMemorySafetyEstablished=True),
            lambda r:r['os'].update(actualFreeBytes=6*GIB-1),lambda r:r['os'].update(freePages=True),
            lambda r:r['os'].update(estimatedReclaimableBytes=48*GIB+1),
            lambda r:r['os'].update(kernelFreePages=0),lambda r:r['os'].update(pressureLevel=3)]:
            row=resources(100);change(row)
            with self.subTest(change=change),self.assertRaises(ValueError):native_resources(row)

    def test_parent_sampling_refusal_is_retained_and_no_reclaimable_credit(self):
        reads=iter(['1\ntotal = 0.00M used = 0.00M free = 0.00M\n',
            'Mach Virtual Memory Statistics: (page size of 16384 bytes)\nPages free: 500000.\nPages inactive: 999999.\n',
            "Now drawing from 'AC Power'\n"])
        row=sample_local(lambda command:next(reads));validate_local(row)
        row['actualFreeBytes']=6*GIB-1
        saved=[];gate=ResourceGate(saved.append,lambda:row,lambda:1)
        with self.assertRaisesRegex(ValueError,'6 GiB'):gate('prelaunch')
        self.assertEqual(saved[0]['actualFreeBytes'],6*GIB-1)
        self.assertEqual(gate.samples,1)

    def test_source_recheck_and_inherited_pins(self):
        pins=PinnedFiles();inherited(pins);pins.recheck()
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/'source';path.write_bytes(b'original')
            pins=PinnedFiles();pins.read(path,100);path.write_bytes(b'changed!')
            with self.assertRaisesRegex(ValueError,'changed'):pins.recheck()

    def test_raw_event_preserves_original_serialization(self):
        with tempfile.TemporaryDirectory() as directory:
            p=Path(directory);(p/'pipes').mkdir();capture=RawEvents(p)
            value=dict(type='ready',record={});raw=b'{ "type": "ready", "record": {} }\n'
            (p/'pipes/worker-0.stdout').write_bytes(raw)
            self.assertEqual(capture(value),digest(raw))
            self.assertEqual((p/'events/00-ready.jsonl').read_bytes(),raw)
            with self.assertRaises(ValueError):capture(value)

    def test_missing_and_false_release_refused(self):
        opened,commands,_,_=self.controls();spec=WorkerSpec(('native',),{},'solo',None)
        v=self.validator()
        with self.assertRaises(ValueError):v.identity(spec,envelope('released',released(),opened['cohort_id']),commands[-1])
        v.ready=True;v.ordinal=4
        for key,value in [('modelLoadCount',2),('modelReleased',False),('allRequestStateRetired',False)]:
            row=released();row[key]=value
            with self.subTest(key=key),self.assertRaises(ValueError):v.identity(spec,envelope('released',row,opened['cohort_id']),commands[-1])

    def test_error_before_first_resource_sample_keeps_failure_receipt(self):
        with tempfile.TemporaryDirectory() as directory:
            p=Path(directory);output=p/'run'
            with patch('run_solo.ResourceGate') as gate,patch('run_solo.inherited') as check,patch('sys.stdout',new=io.StringIO()):
                gate.return_value.side_effect=RuntimeError('Cannot sample resources')
                gate.return_value.samples=0
                code=main(['--deployment',str(p/'deployment'),'--model-dir',str(p/'model'),'--output',str(output)])
            receipt=json.loads((output/'receipt.json').read_bytes())
            self.assertEqual(code,1);self.assertEqual(receipt['status'],'failed')
            self.assertFalse(receipt['nativeExecutionAttempted']);self.assertEqual(receipt['parentResourceLog']['size_bytes'],0)
            check.assert_not_called()


class ProcessChecks(unittest.TestCase):
    @classmethod
    def setUpClass(cls):cls.reference=Reference()

    def run_fake(self,scenario):
        temp=tempfile.TemporaryDirectory();self.addCleanup(temp.cleanup);output=Path(temp.name)
        declared,requests=four_requests('diagnostic:solo')
        spec=WorkerSpec((sys.executable,'-B',str(HERE/'fabricated_solo.py'),scenario),dict(PATH='/usr/bin:/bin',PYTHONDONTWRITEBYTECODE='1'),'solo',None)
        gates=[];cohort,validator,capture=make_cohort(spec,'diagnostic:solo',declared,output,self.reference,gates.append,timeout=15)
        return output,requests,cohort,validator,capture,gates

    def test_one_permission_per_request_and_complete_raw_evidence(self):
        output,requests,cohort,validator,capture,gates=self.run_fake('success')
        with cohort:
            self.assertEqual(len((output/'pipes/worker-0.stdin').read_bytes().splitlines()),1)
            for request in requests:self.assertEqual(cohort.run(request)['prompt_tokens'],8192)
        evidence=cohort.evidence();self.assertTrue(evidence['output_complete']);self.assertTrue(validator.stopped)
        self.assertEqual(evidence['completed_requests'],4);self.assertEqual(evidence['workers'][0]['returncode'],0)
        raw=(output/'pipes/worker-0.stdout').read_bytes();self.assertEqual(len(raw.splitlines()),7)
        self.assertEqual(raw,b''.join((output/item['path']).read_bytes() for item in capture.records))
        controls=[json.loads(line) for line in (output/'pipes/worker-0.stdin').read_bytes().splitlines()]
        self.assertEqual([x['type'] for x in controls],['open']+['run']*4+['shutdown'])
        self.assertTrue(all(not row['performanceQualified'] for row in validator.results))

    def test_numerical_resource_pid_and_release_failures_retire_without_retry(self):
        for scenario in ('bad_logits','bad_resource','bad_pid','bad_release'):
            with self.subTest(scenario=scenario):
                output,requests,cohort,validator,capture,gates=self.run_fake(scenario)
                with self.assertRaises(ValueError):
                    with cohort:
                        for request in requests:cohort.run(request)
                evidence=cohort.evidence();self.assertTrue(evidence['failed'])
                self.assertTrue(all(row['returncode'] is not None for row in evidence['workers']))
                controls=[json.loads(line) for line in (output/'pipes/worker-0.stdin').read_bytes().splitlines()]
                self.assertNotIn('shutdown',[row['type'] for row in controls])
                self.assertFalse(validator.stopped)

    def test_capture_failure_retires_child(self):
        output,requests,cohort,validator,capture,gates=self.run_fake('success')
        validator.capture=lambda event:(_ for _ in ()).throw(OSError('disk full'))
        with self.assertRaisesRegex(OSError,'disk full'):
            with cohort:pass
        self.assertTrue(cohort.evidence()['failed'])
        self.assertTrue(all(row['returncode'] is not None for row in cohort.evidence()['workers']))

    def test_interrupt_after_ready_retires_child(self):
        output,requests,cohort,validator,capture,gates=self.run_fake('success')
        with self.assertRaises(KeyboardInterrupt):
            with cohort:raise KeyboardInterrupt('operator stopped')
        self.assertTrue(all(row['returncode'] is not None for row in cohort.evidence()['workers']))
        self.assertEqual(cohort.evidence()['completed_requests'],0)


if __name__=='__main__':unittest.main()
