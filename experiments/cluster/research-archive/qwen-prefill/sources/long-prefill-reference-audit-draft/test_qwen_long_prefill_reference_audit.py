"""Prospective fake/CPU tests, never reads native candidate output."""
import copy
import importlib.util
import json
from pathlib import Path
import struct
import tempfile
import unittest

HERE=Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location('long_reference_prospective_oracle',HERE/'qwen_long_prefill_reference_audit.py')
a=importlib.util.module_from_spec(spec);spec.loader.exec_module(a)
PROMPT_PATH=HERE.parent/'long-prefill-input-20260914/prompt-8192.json'
PROMPT_SHA='ee6caf0be6391e00ec41df930f0fd6351613969622cbb247b1b4bdaf69afe997'
PROMPT=PROMPT_PATH.read_bytes()
assert a.sha(PROMPT)==PROMPT_SHA


fixture_spec=importlib.util.spec_from_file_location('long_reference_synthetic_fixture',HERE/'reference_fixture.py')
fixture_module=importlib.util.module_from_spec(fixture_spec);fixture_spec.loader.exec_module(fixture_module)


def fixture():
    return fixture_module.make_fixture(a,PROMPT)

BASE=fixture()
def evidence(rows):return rows[1]['evidence']
def execution(rows):return evidence(rows)['execution']
def rehash(rows):evidence(rows)['fingerprint']=a.evidence_fingerprint(evidence(rows))
def encoded(rows):return b'\n'.join(json.dumps(x,separators=(',',':'),allow_nan=False).encode() for x in rows)+b'\n'


class AuditTests(unittest.TestCase):
    def rejected(self,change):
        rows=copy.deepcopy(BASE);change(rows)
        with self.assertRaises((ValueError,KeyError)):a.validate_reports(rows,PROMPT,PROMPT_SHA)

    def test_complete_synthetic_positive(self):
        s=a.validate_reports(copy.deepcopy(BASE),PROMPT,PROMPT_SHA)
        self.assertEqual((s['completedFrames'],s['committedTokens'],s['finalStateComponents']),(16,8192,72))
        self.assertEqual(s['finalStateLogicalBytes'],319946784)
        self.assertEqual((s['argmaxTokenID'],s['maximumTieCount'],s['maximumLogit']),(73,2,18.875))
        self.assertEqual(s['independentlyReconstructedNativeLogitBytes'],496640)
        self.assertEqual((s['independentlyReconstructedStateOffsetComponents'],s['opaqueStateComponentDigests']),(8,64))
        self.assertFalse(s['throughputQualified']);self.assertFalse(s['independentModelForwardPerformed'])

    def test_known_independent_profile_and_request_vectors(self):
        self.assertEqual(a.profile_fingerprint(),'2b7f484488df61c4f6042acfb472a8099828c8a6246819501c88d4f6e07bcc0b')
        self.assertEqual(a.request_identity('00112233-4455-6677-8899-aabbccddeeff',list(range(8192)))[0],
                         'a0f720bd2fc26e70f6cf3e747a8bbd452da4db35e93a3223b6f7a15141e00f01')
        self.assertEqual(a.context()['source']['planSHA256'],'2b5aa52cab49c12cfa44f2348326f956127d2ca15b1c55b5632f447901e56293')

    def test_signed_integer_negative_zero_json(self):
        raw=encoded(BASE).replace(b'-0.0',b'-0')
        s=a.validate_reports(a.parse_rows(raw),PROMPT,PROMPT_SHA)
        self.assertEqual(s['finalLogits']['logicalBytesSHA256'],execution(BASE)['finalLogits']['logicalBytesSHA256'])

    def test_path_api_with_owned_temporary_fake_files(self):
        with tempfile.TemporaryDirectory(prefix='long-reference-cpu-fake-') as td:
            out=Path(td)/'fake.jsonl';prompt=Path(td)/'prompt.json'
            out.write_bytes(encoded(BASE));prompt.write_bytes(PROMPT)
            result=a.validate(out,prompt,PROMPT_SHA)
            self.assertTrue(result['frozenInputsUnchanged']);self.assertEqual(result['stdoutSHA256'],a.sha(out.read_bytes()))

    def test_coherent_source_replay_rejected(self):
        def change(rows):
            x=execution(rows);x['source']['artifactAggregateSHA256']='0'*64;x['sourceLoad']['verifiedAggregateSHA256']='0'*64
            evidence(rows)['resourceAdmission']['expectedArtifactAggregateSHA256']='0'*64;rehash(rows)
        self.rejected(change)

    def test_coherent_environment_replay_rejected(self):
        def change(rows):
            e=evidence(rows);e['arithmeticEnvironment']['requiredValues']['MLX_ENABLE_TF32']='0'
            h=a.sha(a.canonical(e['arithmeticEnvironment']));e['arithmeticEnvironmentSHA256']=h
            e['execution']['source']['arithmeticEnvironmentSHA256']=h;rows[0]['arithmeticEnvironmentSHA256']=h;rehash(rows)
        self.rejected(change)

    def test_coherent_prompt_replay_rejected(self):
        def change(rows):
            x=execution(rows);r=x['request'];r['promptTokenIDs'][0]+=1
            simple,history=a.request_identity(r['request']['requestID'],r['promptTokenIDs'])
            r['steps'],x['commits']=a.frames_and_commits(r['promptTokenIDs']);r['fingerprint']=history
            x['selection']['requestFingerprint']=simple;x['selection']['recordedRequestFingerprint']=history
            rows[0]['recordedRequestFingerprint']=history;evidence(rows)['promptTokenIDsSHA256']=a.sha(','.join(map(str,r['promptTokenIDs'])).encode())
            rehash(rows)
        self.rejected(change)

    def test_coherent_stale65_replay_rejected(self):
        def change(rows):
            x=execution(rows);r=x['request'];r['request']['promptCount']=65;r['request']['chunkSize']=32
            r['promptTokenIDs']=r['promptTokenIDs'][:65];r['steps']=r['steps'][:3];x['commits']=x['commits'][:3]
            x['completedFrames']=3;x['committedTokens']=65;r['fingerprint']='1'*64
            rows[0]['recordedRequestFingerprint']='1'*64;x['selection']['recordedRequestFingerprint']='1'*64;rehash(rows)
        self.rejected(change)

    def test_known_offset_bytes_reject_coherent_recommit(self):
        def change(rows):
            state=execution(rows)['finalState'];entry=next(x for x in state['entries'] if x['component']=='kv.position_offsets')
            entry['sha256']=a.sha(struct.pack('<i',8193));state['fingerprint']=a.state_fingerprint(state['entries']);rehash(rows)
        self.rejected(change)

    def test_opaque_state_digest_limit_is_explicit(self):
        rows=copy.deepcopy(BASE);state=execution(rows)['finalState'];state['entries'][0]['sha256']='0'*64
        state['fingerprint']=a.state_fingerprint(state['entries']);rehash(rows)
        s=a.validate_reports(rows,PROMPT,PROMPT_SHA)
        self.assertEqual(s['opaqueStateComponentDigests'],64)
        self.assertFalse(s['independentModelForwardPerformed'])

    def test_coherent_wrong_state_capacity_rejected(self):
        def change(rows):
            state=execution(rows)['finalState'];entry=next(x for x in state['entries'] if x['component']=='kv.keys')
            entry['shape'][2]=8193;entry['byteCount']+=2048;state['logicalByteCount']+=2048
            state['fingerprint']=a.state_fingerprint(state['entries']);rehash(rows)
        self.rejected(change)

    def test_value_bytes_changed_with_rehashed_envelope_still_rejected(self):
        def change(rows):execution(rows)['finalLogits']['values'][73]=19.0;rehash(rows)
        self.rejected(change)

    def test_wrong_endian_logit_digest_rejected(self):
        def change(rows):
            l=execution(rows)['finalLogits'];raw=b''.join(struct.pack('>H',a.float32_bits(v)>>16) for v in l['values'])
            l['logicalBytesSHA256']=a.sha(raw);rehash(rows)
        self.rejected(change)

    def test_prompt_raw_pin_and_lexeme_rejections(self):
        cases=[b'',b' '*65537,b'[true]',b'[1.0]',b'[1e0]',b'{"tokens":[]}',b'[{"x":1,"x":2}]',
               json.dumps([3]*65).encode(),json.dumps([-1]+[3]*8191).encode(),json.dumps([248320]+[3]*8191).encode()]
        for data in cases:
            with self.subTest(size=len(data)),self.assertRaises(ValueError):a.prompt_tokens(data,a.sha(data))
        with self.assertRaises(ValueError):a.prompt_tokens(PROMPT+b' ',PROMPT_SHA)
        with self.assertRaises(ValueError):a.prompt_tokens(PROMPT,PROMPT_SHA.upper())

    def test_raw_json_duplicate_nonfinite_depth_and_record_rejections(self):
        cases=[b'{"kind":"a","\\u006bind":"b"}\n{}\n',encoded(BASE).replace(b'18.875',b'NaN',1),
               encoded(BASE).replace(b'18.875',b'1e9999',1),b'['*17+b'0'+b']'*17+b'\n{}\n',
               encoded(BASE)+b'{}\n',encoded(BASE)+b'\n',b'{}\n',b'x'*(a.MAX_STDOUT+1)]
        for data in cases:
            with self.subTest(size=len(data)),self.assertRaises((ValueError,OverflowError)):
                a.validate_reports(a.parse_rows(data),PROMPT,PROMPT_SHA)


MUTATIONS={
 'missing_commit':lambda r:execution(r)['commits'].pop(),
 'commit_order':lambda r:execution(r)['commits'].reverse(),
 'wrong_frontier':lambda r:execution(r)['commits'][7].update(committedTokens=4095),
 'nonfinal_full_row':lambda r:execution(r)['commits'][0].update(outputShape=[1,248320]),
 'wrong_native_handle_dtype':lambda r:execution(r)['commits'][0].update(outputDType='float32'),
 'raw_header_count_not_retained':lambda r:execution(r)['sourceLoad'].update(sourceTensorCount=1291),
 'wrong_source_byte_accounting':lambda r:execution(r)['sourceLoad'].update(loadedTensorBytes=1),
 'wrong_source_layout':lambda r:execution(r)['source'].update(sourceParameterLayoutSHA256='0'*64),
 'wrong_profile':lambda r:evidence(r).update(profile='legacy'),
 'missing_state_component':lambda r:execution(r)['finalState']['entries'].pop(),
 'duplicate_state_component':lambda r:execution(r)['finalState']['entries'].__setitem__(1,copy.deepcopy(execution(r)['finalState']['entries'][0])),
 'wrong_ssm_dtype':lambda r:execution(r)['finalState']['entries'][1].update(dtype='bfloat16'),
 'uncommitted_state_digest':lambda r:execution(r)['finalState']['entries'][0].update(sha256='0'*64),
 'lost_signed_zero':lambda r:execution(r)['finalLogits']['values'].__setitem__(0,0.0),
 'non_bf16_value':lambda r:execution(r)['finalLogits']['values'].__setitem__(2,1.0009765625),
 'boolean_logit':lambda r:execution(r)['finalLogits']['values'].__setitem__(2,True),
 'missing_logit_value':lambda r:execution(r)['finalLogits']['values'].pop(),
 'wrong_logit_dtype':lambda r:execution(r)['finalLogits'].update(dtype='float16'),
 'wrong_argmax':lambda r:execution(r)['selection'].update(tokenID=109),
 'wrong_tie_count':lambda r:execution(r)['selection'].update(maximumTieCount=1),
 'wrong_maximum':lambda r:execution(r)['selection'].update(maximumLogit=19.0),
 'wrong_selection_policy':lambda r:execution(r)['selection'].update(policy='argmax'),
 'bool_integer_field':lambda r:evidence(r).update(schemaVersion=True),
 'float_integer_field':lambda r:execution(r).update(completedFrames=16.0),
 'per_frame_capture_claim':lambda r:execution(r).update(perFrameStateCaptures=16),
 'throughput_claim':lambda r:evidence(r).update(throughputMeasurementValid=True),
 'native_compare_claim':lambda r:execution(r).update(candidateNumericalComparisonPerformed=True),
 'timing_field':lambda r:evidence(r).update(elapsedNanoseconds=1),
 'unretired_request':lambda r:execution(r).update(allRequestStateRetired=False),
 'unreleased_model':lambda r:r[1].update(modelReleased=False),
 'ready_after_load':lambda r:r[0].update(verifiedModelLoaded=True),
 'ready_wrong_request':lambda r:r[0].update(recordedRequestFingerprint='0'*64),
 'allocator_peak_inconsistent':lambda r:r[1]['memory'][1].update(peakMLXBytesSinceProcessStart=1),
 'allocator_cache_uncleared':lambda r:r[1]['memory'][1].update(cachedMLXBytes=4),
 'allocator_wrong_phase':lambda r:r[1]['memory'][0].update(phase='after_load'),
 'forged_top_fingerprint':lambda r:evidence(r).update(fingerprint='0'*64),
}
for name,mutate in MUTATIONS.items():
    def test(self,mutate=mutate):self.rejected(mutate)
    setattr(AuditTests,'test_reject_'+name,test)


if __name__=='__main__':unittest.main(verbosity=2)
