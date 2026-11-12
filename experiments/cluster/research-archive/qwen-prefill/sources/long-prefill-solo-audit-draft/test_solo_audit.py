"""Prospective synthetic CPU tests; no solo or rank native candidate reads."""
import copy
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import qwen_long_prefill_solo_audit as audit
import solo_fixture as factory

FIXTURE=None


def fresh():
    global FIXTURE
    if FIXTURE is None:FIXTURE=factory.fixture()
    return dict(FIXTURE,rows=copy.deepcopy(FIXTURE['rows']))


def check(x):return audit.check_solo(x['rows'],x['baseline'],x['prompt'],x['promptSHA'])
def execution(x):return x['rows'][1]['execution']


class SoloAuditTests(unittest.TestCase):
    def test_positive_complete(self):
        r=check(fresh());self.assertEqual(r['completedFrames'],16);self.assertEqual(r['selectedTokenID'],73)
        self.assertEqual(r['baselineMaximumTieCount'],2);self.assertEqual(r['finalStateComponents'],72)
        self.assertFalse(r['candidateNativeBytesIndependentlyReconstructed']);self.assertFalse(r['throughputQualified'])

    def test_roundtrip_and_integer_signed_zero_reference(self):
        x=fresh();a=audit.context();x['rows']=audit.parse_rows(factory.encoded(x['rows']))
        raw=factory.encoded(x['baseline']).replace(b'"values":[-0.0,',b'"values":[-0,')
        self.assertIn(b'"values":[-0,',raw);x['baseline']=a.parse_rows(raw)
        self.assertEqual(check(x)['status'],'passed')

    def test_file_api_fabricated_origin_pin(self):
        x=fresh();a=audit.context()
        with tempfile.TemporaryDirectory(prefix='long-solo-audit-fake-') as temp:
            p=Path(temp);(p/'solo.jsonl').write_bytes(factory.encoded(x['rows']));raw=factory.encoded(x['baseline'])
            (p/'baseline.jsonl').write_bytes(raw);(p/'prompt.json').write_bytes(x['prompt'])
            with patch.object(audit,'BASELINE_SHA',a.sha(raw)):
                r=audit.validate(p/'solo.jsonl',p/'baseline.jsonl',p/'prompt.json',x['promptSHA']);self.assertTrue(r['frozenInputsUnchanged'])
            with self.assertRaisesRegex(ValueError,'Frozen completed'):
                audit.validate(p/'solo.jsonl',p/'baseline.jsonl',p/'prompt.json',x['promptSHA'])

    def test_duplicate_keys_depth_nonfinite_bounds(self):
        raw=factory.encoded(fresh()['rows'])
        altered=[raw.replace(b'"schemaVersion":1',b'"schemaVersion":1,"schemaVersion":1',1),
            b'['*20+b'0'+b']'*20+b'\n{}\n',b'{}\n{"bad":NaN}\n',b'{}\n',raw+b'{}\n',b'x'*(audit.MAX_STDOUT+1)]
        for item in altered:
            with self.assertRaises(ValueError):audit.parse_rows(item)

    def test_coherent_state_digest_change(self):
        x=fresh();state=execution(x)['finalState'];state['entries'][0]['sha256']='1'*64
        state['fingerprint']=audit.context().state_fingerprint(state['entries'])
        with self.assertRaises(ValueError):check(x)

    def test_coherent_stale_request(self):
        x=fresh();old=x['baseline'][1]['evidence']['execution']['request'];execution(x)['request']=copy.deepcopy(old)
        with self.assertRaisesRegex(ValueError,'Fresh solo'):check(x)

    def test_coherent_changed_arithmetic(self):
        x=fresh();r=x['rows'][1];r['arithmeticEnvironment']['contract']='changed'
        r['arithmeticEnvironmentSHA256']=audit.context().sha(audit.context().canonical(r['arithmeticEnvironment']))
        with self.assertRaises(ValueError):check(x)


def mutate(name,change):
    def test(self):
        x=fresh();change(x)
        with self.assertRaises(ValueError,msg=name):check(x)
    setattr(SoloAuditTests,'test_reject_'+name,test)


mutate('legacy_profile',lambda x:x['rows'][1].update(profile='legacy_128_32_v1'))
mutate('stale65',lambda x:execution(x)['request']['request'].update(promptCount=65,chunkSize=32))
mutate('teacher',lambda x:execution(x)['request'].update(teacherTokenIDs=[271]))
mutate('changed_prompt',lambda x:x.update(prompt=x['prompt']+b' '))
mutate('coherent_wrong_input_sha',lambda x:x['rows'][1].update(promptTokenIDsSHA256='1'*64))
mutate('ready_history',lambda x:x['rows'][0].update(recordedRequestFingerprint='1'*64))
mutate('ready_before_load',lambda x:x['rows'][0].update(verifiedModelLoaded=False))
mutate('ready_existing_state',lambda x:x['rows'][0].update(freshRequestStateCreated=True))
mutate('source_tensor_count',lambda x:execution(x)['sourceLoad'].update(sourceTensorCount=1291))
mutate('wrong_artifact',lambda x:execution(x)['source'].update(artifactAggregateSHA256='1'*64))
mutate('source_float16_policy',lambda x:execution(x)['source'].update(bf16ConversionEnabled=False))
mutate('missing_commit',lambda x:execution(x)['commits'].pop())
mutate('wrong_frontier',lambda x:execution(x)['commits'][0].update(committedTokens=1024))
mutate('boolean_frame',lambda x:execution(x)['commits'][0]['frame'].update(sequence=False))
mutate('full_intermediate_row',lambda x:execution(x)['commits'][0].update(outputShape=[1,248320]))
mutate('wrong_tie_index',lambda x:execution(x)['selection'].update(tokenID=109))
mutate('boolean_token',lambda x:execution(x)['selection'].update(tokenID=True))
mutate('nonfinite_selection',lambda x:execution(x)['selection'].update(allLogitsFinite=False))
mutate('invented_tie_count',lambda x:execution(x)['selection'].update(maximumTieCount=2))
mutate('wrong_logit_digest',lambda x:execution(x)['finalLogits'].update(logicalBytesSHA256='1'*64))
mutate('invented_values',lambda x:execution(x)['finalLogits'].update(values=[0]))
mutate('wrong_logit_dtype',lambda x:execution(x)['finalLogits'].update(dtype='float16'))
mutate('wrong_state_dtype',lambda x:execution(x)['finalState']['entries'][0].update(dtype='float32'))
mutate('wrong_state_shape',lambda x:execution(x)['finalState']['entries'][0]['shape'].__setitem__(-1,1))
mutate('missing_state_owner',lambda x:execution(x)['finalState']['entries'].pop())
mutate('duplicate_state_owner',lambda x:execution(x)['finalState']['entries'].__setitem__(1,copy.deepcopy(execution(x)['finalState']['entries'][0])))
mutate('perframe_capture',lambda x:execution(x).update(perFrameStateCaptures=16))
mutate('claimed_native_equality',lambda x:execution(x).update(nativeLogitBytesCompared=True))
mutate('claimed_throughput',lambda x:x['rows'][1].update(throughputMeasurementValid=True))
mutate('claimed_transport',lambda x:execution(x).update(interprocessTransportUsed=True))
mutate('live_request',lambda x:execution(x).update(allRequestStateRetired=False))
mutate('live_model',lambda x:x['rows'][1].update(modelReleased=False))
mutate('timer_wrong_scope',lambda x:execution(x)['timing'].update(excludesLoadReadinessFinalCaptureAndRetirement=False))
mutate('timer_boolean',lambda x:execution(x)['timing'].update(startUptimeNanoseconds=True))
mutate('timer_overflow',lambda x:execution(x)['timing'].update(stopUptimeNanoseconds=2**64))
mutate('timer_zero',lambda x:execution(x)['timing'].update(elapsedNanoseconds=0))
mutate('timer_postclose_overflow',lambda x:execution(x)['timing'].update(postStopThroughRequestCloseNanoseconds=2**64-1))
mutate('timer_wrong_subtraction',lambda x:execution(x)['timing'].update(elapsedNanoseconds=1))
mutate('timer_wrong_rate',lambda x:execution(x)['timing'].update(promptTokensPerFirstTokenSecond=8192))
mutate('timer_nonfinite',lambda x:execution(x)['timing'].update(promptTokensPerFirstTokenSecond=float('inf')))
mutate('timer_fractional',lambda x:execution(x)['timing'].update(elapsedNanoseconds=2e9))
mutate('cache_present',lambda x:x['rows'][1]['memory'][-1].update(cachedMLXBytes=1))
mutate('memory_peak_decreases',lambda x:x['rows'][1]['memory'][-1].update(peakMLXBytesSinceProcessStart=1))


if __name__=='__main__':unittest.main(verbosity=2)
