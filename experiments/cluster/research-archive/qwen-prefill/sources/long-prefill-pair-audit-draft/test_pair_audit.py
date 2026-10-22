"""Substantive prospective fake/CPU checks; no actual prompt/candidate reads."""
import copy
import json
from pathlib import Path
import socket
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import pair_fixture
import pair_final
import pair_wire
import qwen_long_prefill_pair_audit as audit


class PairAuditTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.a,cls.prompt,cls.original=pair_fixture.fixture()
        cls.pin=cls.a.sha(cls.prompt)

    def check(self, rows=None):
        with patch.object(subprocess,'Popen',side_effect=AssertionError('No processes in CPU validator')), patch.object(socket,'socket',side_effect=AssertionError('No sockets in CPU validator')):
            return audit.check_pair(self.a, rows if rows is not None else self.original, self.prompt, self.pin)

    def rejected(self, change):
        rows=copy.deepcopy(self.original);change(rows)
        with self.assertRaises((ValueError,KeyError,TypeError)):self.check(rows)

    def test_complete_fake_pair_and_scope(self):
        result=self.check()
        self.assertEqual((result['completedFrames'],result['stageCommits'],result['canonicalTensors']),(16,32,927))
        self.assertEqual(result['stageLogicalStateBytes'],[159973392,159973392])
        self.assertEqual((result['selectedTokenID'],result['baselineMaximumTieCount']),(73,2))
        self.assertEqual(len(result['reconstructedCanonicalEnvelopeHashes']),16)
        for key in ('candidateNativeLogitBytesCompared','candidateFullLogitValuesAvailable','candidateMaximumTieCountComputed',
                    'throughputQualified','physicalTransferQualified','interprocessTransportUsed','independentModelForwardPerformed'):
            self.assertIs(result[key],False)

    def test_generated_wire_domain_matches_frozen_independent_vector(self):
        p=Path(__file__).resolve().parent.parent/'long-prefill-wire-draft/wire-vectors-20260914.json'
        vectors=json.loads(p.read_bytes())['profiled']
        self.assertEqual(pair_wire.fingerprint(self.a,'qwen-profiled-prefill-start-agreement-v1',vectors['agreement']),vectors['agreementFingerprint'])
        self.assertEqual(pair_wire.fingerprint(self.a,'qwen-profiled-prefill-boundary-envelope-v1',vectors['boundary']['content']),vectors['boundary']['fingerprint'])
        self.assertNotEqual(vectors['boundary']['fingerprint'],vectors['boundary']['wireBytesSHA256'])

    def test_missing_duplicate_reordered_frames(self):
        for operation in ('missing','duplicate','reordered'):
            def change(rows):
                frames=rows[1]['comparison']['frames']
                if operation=='missing':frames.pop()
                elif operation=='duplicate':frames[8]=copy.deepcopy(frames[7])
                else:frames[0],frames[1]=frames[1],frames[0]
            with self.subTest(operation=operation):self.rejected(change)

    def test_coherently_rehashed_wrong_header_geometry(self):
        for field,value in [('version',1),('shape',[1,513,4096]),('byteCount',4194306),('dtype','float32')]:
            def change(rows):
                c=rows[1]['comparison'];record=c['frames'][3];record['boundary'][field]=value
                raw=self.a.canonical(dict(version=4,flow=pair_wire.FLOW,kind='boundary',
                    agreementFingerprint=c['agreementFingerprint'],boundary=record['boundary']))
                record['envelopeWireBytesSHA256']=self.a.sha(raw)
                record['envelopeFingerprint']=self.a.sha(b'qwen-profiled-prefill-boundary-envelope-v1\n'+raw)
            with self.subTest(field=field):self.rejected(change)

    def test_wrong_raw_vs_domain_hash_rejected(self):
        self.rejected(lambda r:r[1]['comparison']['frames'][0].update(envelopeFingerprint=r[1]['comparison']['frames'][0]['envelopeWireBytesSHA256']))

    def test_rehashed_environment_and_policy_disagreement(self):
        for key,value in [('arithmeticEnvironmentSHA256','0'*64),('schedulingPolicy','prompt_lookahead_one_v1'),('profile','legacy')]:
            def change(rows):
                c=rows[1]['comparison'];c['agreement'][key]=value
                c['agreementFingerprint']=pair_wire.fingerprint(self.a,'qwen-profiled-prefill-start-agreement-v1',c['agreement'])
            with self.subTest(key=key):self.rejected(change)

    def test_swapped_stage_storage_and_coherent_byte_count(self):
        self.rejected(lambda r:r[1]['stageLoads'].reverse())
        def change(rows):
            load=rows[1]['stageLoads'][0];load['activeTensors'][0]['byteCount']+=2
            load['loadedTensorBytes']+=2;load['activeMappingSHA256']=self.a.sha(self.a.canonical(load['activeTensors']))
        self.rejected(change)

    def test_native_commit_identity_and_frontier(self):
        for key,value in [('committedTokens',8192),('outputShape',[1,248320]),('recordedRequestFingerprint','0'*64)]:
            with self.subTest(key=key):self.rejected(lambda r:r[1]['comparison']['frames'][0]['consumer'].update({key:value}))
        self.rejected(lambda r:r[1]['comparison']['frames'][0]['producer']['identity'].update(stageIndex=1))

    def test_rehashed_state_divergence_duplicate_or_dtype(self):
        for mode in ('digest','duplicate','dtype'):
            def change(rows):
                final=rows[1]['comparison']['finalDigests'][0];entries=final['finalState']['entries']
                if mode=='digest':entries[0]['sha256']='0'*64
                elif mode=='duplicate':entries[1]=copy.deepcopy(entries[0])
                else:entries[0]['dtype']='float32'
                final['finalState']['fingerprint']=self.a.state_fingerprint(entries)
                final['fingerprint']=pair_final.final_fingerprint(self.a,final)
            with self.subTest(mode=mode):self.rejected(change)

    def test_rehashed_logit_metadata_and_argmax_divergence(self):
        for key,value in [('logicalBytesSHA256','0'*64),('dtype','float32'),('byteCount',993280)]:
            def change(rows):
                final=rows[1]['comparison']['finalDigests'][1];final['finalLogits'][key]=value
                final['fingerprint']=pair_final.final_fingerprint(self.a,final)
            with self.subTest(key=key):self.rejected(change)
        self.rejected(lambda r:r[1]['comparison']['selectedToken'].update(tokenID=109))

    def test_retirement_capabilities_and_closed_schemas(self):
        cases=[lambda r:r[0].update(baselineModelReleasedBeforeStageLoading=False),
            lambda r:r[1].update(stageModelsReleased=False),lambda r:r[1].update(allRequestStateRetired=False),
            lambda r:r[1]['comparison'].update(candidateNativeBytesComparedDirectly=True),
            lambda r:r[1]['comparison'].update(throughputMeasurementValid=True),
            lambda r:r[1]['comparison']['finalDigests'][0].update(finalLogits=None),
            lambda r:r[1]['comparison']['finalDigests'][1]['finalLogits'].update(values=[0]),
            lambda r:r[1].update(extra=0),lambda r:r[1]['stageLoads'][0].update(extra=0),
            lambda r:r[1].update(schemaVersion=True)]
        for i,change in enumerate(cases):
            with self.subTest(case=i):self.rejected(change)

    def test_allocator_phase_peak_and_cache_assertions(self):
        self.rejected(lambda r:r[1]['memory'][2].update(peakMLXBytesSinceProcessStart=1))
        self.rejected(lambda r:r[1]['memory'][-1].update(cachedMLXBytes=1))
        self.rejected(lambda r:r[0]['memory'][1].update(phase='wrong'))

    def test_raw_json_and_temporary_file_api(self):
        raw=b'\n'.join(json.dumps(row,separators=(',',':'),allow_nan=False).encode() for row in self.original)+b'\n'
        rows=audit.parse_rows(self.a,raw.replace(b'-0.0',b'-0'))
        self.assertEqual(self.check(rows)['selectedTokenID'],73)
        with tempfile.TemporaryDirectory(prefix='pair-cpu-fake-') as td:
            out=Path(td)/'fake.jsonl';prompt=Path(td)/'fake-prompt.json'
            out.write_bytes(raw);prompt.write_bytes(self.prompt)
            self.assertTrue(audit.validate(self.a,out,prompt,self.pin)['frozenInputsUnchanged'])
        for bad in (raw+b'{}\n',raw+b'\n',b'{"kind":1,"\\u006bind":2}\n{}\n',b'x'*(audit.MAX_STDOUT+1)):
            with self.assertRaises((ValueError,UnicodeError)):audit.parse_rows(self.a,bad)
        with self.assertRaises(ValueError):audit.check_pair(self.a,self.original,self.prompt+b' ',self.pin)


if __name__=='__main__':unittest.main()
