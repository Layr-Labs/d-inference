"""Synthetic state hashes and full fabricated BF16 rows; no native candidate IO."""
import copy
import hashlib
import json
import math
from pathlib import Path
import socket
import struct
import tempfile
import unittest
from unittest.mock import patch
import audit_short_parity as audit
from outer_fixture import rows,raw,TOKENS,PROFILE,PROMPT,TEACHER


def reseal(values):
    baseline=values[0]['baseline'];comparison=values[1]['pair']['comparison']
    for original,candidate in zip(baseline['frames'],comparison['frames']):
        state=original['state'];state['logicalByteCount']=sum(x['byteCount'] for x in state['entries'])
        state['fingerprint']=audit.state_digest(state)
        candidate.update(stateEntriesCompared=len(state['entries']),logicalStateBytesPerSide=state['logicalByteCount'],globalStateSHA256=state['fingerprint'])
    baseline['fingerprint']=audit.baseline_digest(baseline)
    comparison['baselineEvidenceSHA256']=baseline['fingerprint'];values[1]['baselineEvidenceSHA256']=baseline['fingerprint']


def numeric_fixture(profile):
    values=rows(profile);e=audit.expected(profile);layout=e['sourceParameterLayoutSHA256']
    baseline=values[0]['baseline'];comparison=values[1]['pair']['comparison']
    baseline['source']['sourceParameterLayoutSHA256']=layout;comparison['source']['sourceParameterLayoutSHA256']=layout
    values[0]['load'].update(parameterLayoutSHA256=layout,sourceTensorCount=e['tensorCount'],largestHostTensorBytes=e['largestTensorBytes'])
    for stage in values[1]['pair']['stageLoads']:stage['sourceParameterLayoutSHA256']=layout
    numbers=[0.0]*248320;numbers[0]=-0.0;numbers[1]=0.5;numbers[2]=-2.0
    data=b'\x00\x80\x00\x3f\x00\xc0'+b'\0\0'*(248320-3)
    record=dict(shape=[1,248320],dtype='bfloat16',byteCount=len(data),logicalBytesSHA256=audit.digest(data),values=numbers)
    for i,frontier in enumerate([2,3,4]):
        entries=[]
        for geometry in audit.state_geometry(e,frontier):
            identity=audit.digest(struct.pack('<i',frontier)) if geometry['component']=='kv.position_offsets' else audit.digest(('invented|'+str(frontier)+'|'+str(geometry)).encode())
            entries.append(dict(geometry,sha256=identity))
        baseline['frames'][i]['state']=dict(committedTokens=frontier,entries=entries,logicalByteCount=0,fingerprint='0'*64)
        if i:
            baseline['frames'][i]['logits']=copy.deepcopy(record)
            comparison['frames'][i]['logits']=copy.deepcopy(record)
    reseal(values);return values


class AuditTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):cls.templates={name:numeric_fixture(name) for name in audit.PROFILES}
    def setUp(self):
        self.blocks=[patch('subprocess.Popen',side_effect=AssertionError('No process allowed')),
            patch('subprocess.run',side_effect=AssertionError('No process allowed')),patch.object(socket,'socket',side_effect=AssertionError('No network allowed'))]
        for p in self.blocks:p.start()
    def tearDown(self):
        for p in reversed(self.blocks):p.stop()
    def fixture(self):return copy.deepcopy(self.templates[PROFILE])
    def check(self,values,profile=PROFILE):return audit.audit(raw(values),profile,TOKENS)
    def test_both_registered_profiles_and_scopes(self):
        for profile,expected in [(PROFILE,[51576864,51609632,51642400]),('registered_qwen38_27b',[154075200,154140736,154206272])]:
            v=self.check(self.templates[profile],profile)
            self.assertTrue(v['passed']);self.assertEqual(v['stateBytesPerFrame'],expected)
            self.assertEqual(v['stateEntriesPerFrame'],72 if profile==PROFILE else 144)
            self.assertEqual(v['independentlyReconstructedNativeLogitRows'],4);self.assertEqual(v['independentlyComparedNativeLogitPairs'],2)
            for flag in ['rawStateValueParityIndependentlyEstablished','loadedStageInventoryIndependentlyReaudited','nativeLifetimeIndependentlyObserved',
                         'planAndProfileSerializationIndependentlyReplayed','weightTensorValuesRead','physicalTwoMachineExecution','throughputMeasurementValid']:
                self.assertIs(v[flag],False)
    def test_swift_integer_spelling_negative_zero(self):
        value=raw(self.templates[PROFILE]);self.assertEqual(value.count(b'"values":[-0.0,'),4)
        value=value.replace(b'"values":[-0.0,',b'"values":[-0,')
        result=audit.audit(value,PROFILE,TOKENS);self.assertTrue(result['signedZeroPreserved'])
    def test_sign_change_cannot_hide_behind_numeric_equality(self):
        v=self.fixture();v[1]['pair']['comparison']['frames'][1]['logits']['values'][0]=0.0
        with self.assertRaisesRegex(ValueError,'SHA differs'):self.check(v)
    def test_coherent_different_native_row_is_rejected(self):
        v=self.fixture();row=v[1]['pair']['comparison']['frames'][1]['logits'];row['values'][3]=1.0
        row['logicalBytesSHA256']=audit.digest(b'\x00\x80\x00\x3f\x00\xc0\x80\x3f'+b'\0\0'*(248320-4))
        with self.assertRaisesRegex(ValueError,'native bytes differ'):self.check(v)
    def test_nonfinite_boolean_or_non_bf16_row(self):
        for value in [True,float('nan'),float('inf'),0.1,1e300]:
            v=self.fixture();v[0]['baseline']['frames'][1]['logits']['values'][4]=value
            with self.subTest(value=value),self.assertRaises(ValueError):self.check(v)
    def test_truncated_or_extra_vocabulary_is_rejected(self):
        for count in [248319,248321]:
            v=self.fixture();v[0]['baseline']['frames'][1]['logits']['values']=[0.0]*count
            with self.assertRaises(ValueError):self.check(v)
    def test_state_geometry_resealed_mutations(self):
        for field,value in [('globalLayerIndex',True),('shape',[1,3,8193]),('dtype','float32'),('component','other'),('byteCount',1.0)]:
            v=self.fixture();v[0]['baseline']['frames'][0]['state']['entries'][0][field]=value;reseal(v)
            with self.subTest(field=field),self.assertRaises(ValueError):self.check(v)
    def test_state_coverage_and_order(self):
        for action in ['remove','duplicate','reverse']:
            v=self.fixture();entries=v[0]['baseline']['frames'][0]['state']['entries']
            if action=='remove':entries.pop()
            elif action=='duplicate':entries[1]=copy.deepcopy(entries[0])
            else:entries.reverse()
            reseal(v)
            with self.assertRaises(ValueError):self.check(v)
    def test_known_position_offset_resealed_mismatch(self):
        v=self.fixture();entry=next(x for x in v[0]['baseline']['frames'][0]['state']['entries'] if x['component']=='kv.position_offsets')
        entry['sha256']=audit.digest(struct.pack('<i',3));reseal(v)
        with self.assertRaisesRegex(ValueError,'position offset'):self.check(v)
    def test_raw_recurrent_payload_not_claimed(self):
        v=self.fixture();v[0]['baseline']['frames'][0]['state']['entries'][0]['sha256']='e'*64;reseal(v)
        result=self.check(v);self.assertFalse(result['rawStateValueParityIndependentlyEstablished'])
    def test_state_and_baseline_digest_mismatches(self):
        for path in [(0,'baseline','frames',0,'state','fingerprint'),(1,'pair','comparison','frames',0,'globalStateSHA256'),(0,'baseline','fingerprint')]:
            v=self.fixture();p=v
            for k in path[:-1]:p=p[k]
            p[path[-1]]='f'*64
            with self.assertRaises(ValueError):self.check(v)
    def test_closed_optional_frame_and_state_fields(self):
        for target,key,value in [('original','logits',None),('candidate','nativeLogitBytesExact',None),('state','unknown',0)]:
            v=self.fixture();first=v[0]['baseline']['frames'][0]
            obj=first if target=='original' else v[1]['pair']['comparison']['frames'][0] if target=='candidate' else first['state']
            obj[key]=value
            with self.assertRaises(ValueError):self.check(v)
    def test_resealed_wrong_full_layout(self):
        v=self.fixture();v[0]['baseline']['source']['sourceParameterLayoutSHA256']='f'*64
        v[1]['pair']['comparison']['source']['sourceParameterLayoutSHA256']='f'*64;v[0]['load']['parameterLayoutSHA256']='f'*64
        for s in v[1]['pair']['stageLoads']:s['sourceParameterLayoutSHA256']='f'*64
        reseal(v)
        with self.assertRaisesRegex(ValueError,'registered full layout'):self.check(v)
    def test_raw_token_pin_history_binding(self):
        tokens=copy.deepcopy(TOKENS);tokens['prompt']['sha256']='f'*64
        with self.assertRaises(ValueError):audit.audit(raw(self.templates[PROFILE]),PROFILE,tokens)
    def test_failure_receipt_preserved_new_output_only(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);p=root/'p';t=root/'t';s=root/'stdout';out=root/'audit.json';p.write_bytes(PROMPT);t.write_bytes(TEACHER);s.write_bytes(b'{}\n')
            args=['audit','--stdout',str(s),'--stdout-sha256','0'*64,'--tokens-file',str(p),'--tokens-sha256',TOKENS['prompt']['sha256'],
                '--teacher-tokens-file',str(t),'--teacher-tokens-sha256',TOKENS['teacher']['sha256'],'--profile',PROFILE,'--output',str(out)]
            with patch('sys.argv',args),patch('builtins.print'):self.assertEqual(audit.main(),1)
            before=out.read_bytes();self.assertFalse(json.loads(before)['passed']);self.assertEqual(out.stat().st_mode&0o777,0o600)
            with patch('sys.argv',args),self.assertRaises(ValueError):audit.main()
            self.assertEqual(out.read_bytes(),before)

if __name__=='__main__':unittest.main()
