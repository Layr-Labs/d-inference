"""Prospective CPU only: no subprocess, sockets, Swift or model payloads."""
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import socket
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
sys.dont_write_bytecode = True
import cut12_expected as metadata
import qwen_layer_stage_cut12_audit as oracle
import audit_cut12 as driver
from cut12_test_fixture import ROOT, old_records, fake_pair, refresh_storage, baseline_fingerprint, state_hash

DRAFT = Path(__file__).parent
CONTROL = ROOT/'runs/stage-cut-plan-control-20260914'


class Cut12Tests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.expected = metadata.parse((DRAFT/'cut12-expected.json').read_bytes())
        cls.configuration = (CONTROL/'original-config.json').read_bytes()
        cls.control_bytes = (CONTROL/'stdout.json').read_bytes()
        cls.control = metadata.parse(cls.control_bytes)
        cls.base = fake_pair(cls.expected)

    def setUp(self):
        self.guards = [patch.object(subprocess,'run',side_effect=AssertionError('No processes')),
            patch.object(subprocess,'Popen',side_effect=AssertionError('No processes')),
            patch.object(socket,'socket',side_effect=AssertionError('No sockets'))]
        for guard in self.guards: guard.start()
        self.addCleanup(lambda: [guard.stop() for guard in self.guards])

    def pair(self):
        # Full row lists are immutable by convention in these fixtures. Deep
        # copies preserve isolation for the individual mutation cases below.
        return copy.deepcopy(self.base)

    def reject(self,pair,pattern=None):
        with self.assertRaisesRegex(ValueError,pattern or '.'):
            oracle.check_recorded_pair(*pair,self.expected)

    def test_prospective_cut12_positive(self):
        result = oracle.check_recorded_pair(*self.base,self.expected)
        self.assertEqual(result['inventory']['activeTensorBytes'],[2032294848,3005746752])
        self.assertEqual(result['independentlyVerifiedRawLogitRows'],8)
        self.assertEqual(result['stateEntriesPerFrame'],72)

    def test_bounded_file_adapter_positive_and_changed_history(self):
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory);checkpoint,report=self.base
            (path/'stdout.jsonl').write_bytes(b'\n'.join(metadata.canonical(row) for row in self.base)+b'\n')
            recorded=checkpoint['baseline']['request']
            (path/'prompt.json').write_bytes(metadata.canonical(recorded['promptTokenIDs']))
            (path/'teacher.json').write_bytes(metadata.canonical(recorded['teacherTokenIDs']))
            result=driver.validate(path/'stdout.jsonl',path/'prompt.json',path/'teacher.json')
            self.assertEqual(result['explicitStageCut'],12)
            self.assertFalse(result['sourceAndRuntimeProvenanceIndependentlyVerified'])
            (path/'teacher.json').write_bytes(b'[4087,13,272]')
            with self.assertRaisesRegex(ValueError,'pinned natural prefix/teacher'):
                driver.validate(path/'stdout.jsonl',path/'prompt.json',path/'teacher.json')

    def test_rederive_expected_exact(self):
        basis=(ROOT/'qwen-layer-stage-real9b-expected-20260913.json').read_bytes()
        result=metadata.derive(basis,self.configuration,self.control_bytes)
        self.assertEqual(metadata.canonical(result),metadata.canonical(self.expected))
        self.assertEqual([s['activeTensorCount'] for s in result['stages']],[348,579])
        self.assertTrue(all(f['stageEntryCounts']==[27,45] for f in result['stateFrames']))

    def test_old16_record_is_refused(self):
        self.reject(old_records(),'Pinned real source identity differs: planSHA256')

    def test_old16_frozen_helper_still_passes(self):
        path=ROOT/'qwen_layer_stage_recorded_audit.py'
        self.assertEqual(metadata.digest(path.read_bytes()),'ba943e3ec2157447d7725ab3ca030bb398813c82be6d4d4a1024d4fbf98d29e4')
        spec=importlib.util.spec_from_file_location('frozen_old_cut16',path)
        module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
        result=module.check_recorded_pair(*old_records(),metadata.parse((ROOT/'qwen-layer-stage-real9b-expected-20260913.json').read_bytes()))
        self.assertEqual(result['independentlyVerifiedRawLogitRows'],8)

    def test_plan_stage_construction_pins(self):
        for index in (0,1):
            for field in ('stagePlanSHA256','constructionConfigurationSHA256'):
                with self.subTest(index=index,field=field):
                    pair=self.pair();pair[1]['stageLoads'][index][field]='1'*64
                    refresh_storage(*pair)
                    self.reject(pair,'Pinned cut12 stage identity')

    def test_coherent_wrong_plan(self):
        pair=self.pair()
        pair[0]['baseline']['source']['planSHA256']='1'*64
        pair[1]['comparison']['source']['planSHA256']='1'*64
        for stage in pair[1]['stageLoads']:stage['planSHA256']='1'*64
        refresh_storage(*pair)
        value=baseline_fingerprint(pair[0]['baseline']);pair[0]['baseline']['fingerprint']=value
        pair[1]['comparison']['baselineEvidenceSHA256']=value
        self.reject(pair,'Pinned real source identity differs: planSHA256')

    def test_wrong_local_cut_origin(self):
        pair=self.pair();rows=pair[1]['stageLoads'][1]['activeTensors']
        row=next(x for x in rows if '.layers.12.' in x['sourceName'])
        row['localName']=row['localName'].replace('.layers.0.','.layers.12.')
        rows.sort(key=lambda x:x['localName']);refresh_storage(*pair)
        self.reject(pair,'Local mapping differs')

    def test_wrong_layer_boundary_owner(self):
        pair=self.pair();rows=pair[1]['stageLoads'][0]['activeTensors']
        row=next(x for x in rows if '.layers.11.' in x['sourceName'])
        row['sourceName']=row['sourceName'].replace('.layers.11.','.layers.12.')
        refresh_storage(*pair)
        self.reject(pair,'Wrong explicit cut12 source layer owner')

    def test_missing_duplicate_and_excluded_parameters(self):
        for mutation in ('missing','duplicate','vision'):
            with self.subTest(mutation=mutation):
                pair=self.pair();rows=pair[1]['stageLoads'][0]['activeTensors']
                if mutation=='missing':rows.pop()
                elif mutation=='duplicate':rows[-1]=copy.deepcopy(rows[-2])
                else:rows[-1]['sourceName']='vision_tower.model.layers.0.weight'
                refresh_storage(*pair);self.reject(pair)

    def test_retained_source_count(self):
        pair=self.pair()
        for stage in pair[1]['stageLoads']:
            stage['storageCommitment']['sourceTensorCount']=1291
            stage['storageCommitmentSHA256']=metadata.digest(metadata.canonical(stage['storageCommitment']))
        pair[1]['comparison']['stageStorageCommitmentSHA256']=pair[1]['stageLoads'][0]['storageCommitmentSHA256']
        self.reject(pair,'Common source accounting differs')

    def test_inert_shape_and_dtype_policy(self):
        for mutation in ('inert','dtype'):
            pair=self.pair()
            if mutation=='inert':pair[1]['stageLoads'][0]['inertModules'][0]['parameters'][0]['shape']=[2,4096]
            else:pair[1]['stageLoads'][0]['activeTensors'][0]['loadedDType']='float32'
            refresh_storage(*pair);self.reject(pair)

    def test_coherent_state_shape(self):
        pair=self.pair();state=pair[0]['baseline']['frames'][0]['state'];entry=state['entries'][0]
        entry['shape']=[1,6,4096]
        state['fingerprint']=state_hash(state)
        pair[1]['comparison']['frames'][0]['globalStateSHA256']=state['fingerprint']
        value=baseline_fingerprint(pair[0]['baseline']);pair[0]['baseline']['fingerprint']=value
        pair[1]['comparison']['baselineEvidenceSHA256']=value
        self.reject(pair,'Independent state component geometry')

    def test_raw_logit_pair_with_recomputed_digest(self):
        pair=self.pair();row=pair[1]['comparison']['frames'][2]['logits']
        row['values'][0]=1.0 if row['values'][0]!=1.0 else 2.0
        raw=b''.join(struct.pack('<H',struct.unpack('<I',struct.pack('<f',v))[0]>>16) for v in row['values'])
        row['logicalBytesSHA256']=metadata.digest(raw)
        self.reject(pair,'Baseline/staged native logit bytes differ')

    def test_negative_zero_byte_identity(self):
        raw=b'\x00\x80'
        record=dict(shape=[1,1],dtype='bfloat16',byteCount=2,logicalBytesSHA256=metadata.digest(raw),values=[-0.0])
        self.assertEqual(oracle.logical_bytes(record,1,'bfloat16'),raw)
        record['values']=[0.0]
        with self.assertRaisesRegex(ValueError,'SHA differs'):oracle.logical_bytes(record,1,'bfloat16')

    def test_false_retirement_and_throughput(self):
        for field in ('allRequestStateRetired','throughputMeasurementValid'):
            pair=self.pair();pair[1]['comparison'][field]=field=='throughputMeasurementValid'
            self.reject(pair,'Evidence flag differs')

    def test_expected_metadata_cannot_be_coherently_changed(self):
        expected=copy.deepcopy(self.expected);expected['stages'][0]['sourceLayerEnd']=16
        with self.assertRaisesRegex(ValueError,'Exact prospectively derived'):
            oracle.check_recorded_pair(*self.base,expected)

    def test_control_semantics_and_hash_mutations(self):
        for mutation in ('range','layer_map','roots','mtp','gate_type','construction','stage_hash','plan_hash','unknown'):
            with self.subTest(mutation=mutation):
                c=copy.deepcopy(self.control);s=c['stages'][1]
                if mutation=='range':s['sourceLayerStart']=16
                elif mutation=='layer_map':s['layers'][0]['localIndex']=12
                elif mutation=='roots':s['activeModuleRoots'].append('language_model.model.embed_tokens')
                elif mutation in ('mtp','gate_type'):
                    config=metadata.parse(s['constructionConfigurationUTF8'])
                    if mutation=='mtp':config['text_config']['mtp_num_hidden_layers']=True
                    else:config['text_config']['attn_output_gate']=1
                    s['constructionConfigurationUTF8']=json.dumps(config,separators=(',',':'))
                    s['constructionConfigurationSHA256']=metadata.digest(s['constructionConfigurationUTF8'].encode())
                elif mutation=='construction':s['constructionConfigurationSHA256']='2'*64
                elif mutation=='stage_hash':s['fingerprint']='3'*64
                elif mutation=='plan_hash':c['planSHA256']='4'*64
                else:c['unknown']=True
                with self.assertRaises(ValueError):metadata.check_plan_control(c,self.configuration)

    def test_input_and_parser_fail_closed(self):
        recorded=self.base[0]['baseline']['request'];prompt=recorded['promptTokenIDs'];teacher=recorded['teacherTokenIDs']
        driver.check_inputs(prompt,teacher)
        for altered in (teacher[::-1],[4087,13,272],[4087,13], [True,13,271]):
            with self.assertRaises(ValueError):driver.check_inputs(prompt,altered)
        for raw in (b'{"x":1,"x":2}',b'{"x":NaN}',b'{"x":1e309}'):
            with self.assertRaises(ValueError):metadata.parse(raw)
        self.assertEqual(struct.pack('<f',metadata.parse(b'[-0]')[0]),b'\x00\x00\x00\x80')
        for raw in (b'{}',b'{}\n',b'{}\n{}\n{}\n',b'diagnostic\n{}\n'):
            with self.assertRaises((ValueError,json.JSONDecodeError)):driver.records(raw)


if __name__=='__main__':
    unittest.main()
