"""Prospective CPU-only malformed/coherent-tampering checks; no native outputs."""
import copy
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import qwen_long_prefill_rank_audit as audit
import rank_dependencies as dep
import rank_fixture as factory

FIXTURES={}


def fresh(policy='serial_v1'):
    if policy not in FIXTURES:FIXTURES[policy]=factory.fixture(policy)
    x=FIXTURES[policy]
    return dict(x,ranks=copy.deepcopy(x['ranks']))


def check(x):
    return audit.check_rank_pair(x['ranks'],x['baseline'],x['prompt'],x['promptSHA'],x['epoch'],x['policy'])


def execution(x,rank=0):return x['ranks'][rank][1]['execution']


def phase(x,name,rank=0):return next(row for row in execution(x,rank)['actions'] if row['action']==name)


def rewrite_frame(x,index,change):
    a=dep.context()[0]
    obj=json.loads(execution(x)['frames'][index]['exactEnvelopeJSON']);change(obj)
    raw=a.canonical(obj)
    for rank in range(2):
        row=execution(x,rank)['frames'][index]
        row.update(exactEnvelopeJSON=raw.decode(),envelopeFingerprint=a.sha(b'qwen-profiled-prefill-boundary-envelope-v1\n'+raw),
            envelopeWireBytesSHA256=a.sha(raw))
    if index==15:
        def change_token(token):
            token['finalBoundaryEnvelopeFingerprint']=execution(x)['frames'][index]['envelopeFingerprint']
            token['finalBoundaryWireBytesSHA256']=execution(x)['frames'][index]['envelopeWireBytesSHA256']
        rewrite_token(x,change_token)


def rewrite_token(x,change):
    a=dep.context()[0]
    obj=json.loads(execution(x)['exactTokenPacketJSON']);change(obj);raw=a.canonical(obj)
    for rank in range(2):execution(x,rank).update(exactTokenPacketJSON=raw.decode(),
        tokenPacketFingerprint=a.sha(b'qwen-profiled-prefill-first-token-packet-v1\n'+raw),tokenPacketWireBytesSHA256=a.sha(raw))


def restate(x,rank=0):
    a,_,final,_=dep.context();d=execution(x,rank)['finalDigest']
    d['finalState']['fingerprint']=a.state_fingerprint(d['finalState']['entries'])
    d['fingerprint']=final.final_fingerprint(a,d)


class RankAuditTests(unittest.TestCase):
    def test_positive_serial(self):
        r=check(fresh());self.assertEqual(r['actionCounts'],[204,235]);self.assertEqual(r['nativeCommitAssertions'],32)
        self.assertEqual(r['selectedTokenID'],73);self.assertEqual(r['baselineMaximumTieCount'],2)
        self.assertEqual(r['preparedAheadFrames'],[0,0]);self.assertFalse(r['throughputQualified'])

    def test_positive_lookahead(self):
        x=fresh('prompt_lookahead_one_v1');r=check(x)
        self.assertEqual(r['preparedAheadFrames'],[15,0]);p=phase(x,'send.beginConsumedDrain')
        self.assertEqual((p['nativeCommittedTokens'],p['completedBoundaryCount'],p['explicitPreparedBoundarySlots'],p['pendingConsumedFrameSlots']),
            (1024,0,1,1))

    def test_serialized_roundtrip_preserves_negative_zero_integer(self):
        x=fresh();a=dep.context()[0]
        x['ranks']=[audit.parse_rows(factory.encoded(rows)) for rows in x['ranks']]
        # Swift JSON can spell Float(-0) as integer -0; base parser must preserve it.
        raw=factory.encoded(x['baseline']).replace(b'"values":[-0.0,',b'"values":[-0,')
        self.assertIn(b'"values":[-0,',raw)
        x['baseline']=a.parse_rows(raw);self.assertEqual(check(x)['status'],'passed')

    def test_epoch_is_independently_supplied(self):
        x=factory.fixture(epoch='1'*32);x['epoch']=factory.EPOCH
        with self.assertRaises(ValueError):check(x)

    def test_stale_baseline_request_replay(self):
        x=fresh();uid=x['baseline'][1]['evidence']['execution']['request']['request']['requestID']
        x['epoch']=uid.replace('-','').lower()
        with self.assertRaisesRegex(ValueError,'Fresh rank request'):check(x)

    def test_changed_source_count_recomputed_commitment(self):
        x=fresh();a=dep.context()[0]
        for rows in x['ranks']:
            load=rows[1]['sourceLoad'];load['storageCommitment']['sourceTensorCount']=1291
            load['storageCommitmentSHA256']=a.sha(a.canonical(load['storageCommitment']))
        with self.assertRaises(ValueError):check(x)

    def test_changed_numerical_state_recomputed_whole_digest(self):
        x=fresh();execution(x)['finalDigest']['finalState']['entries'][0]['sha256']='1'*64;restate(x)
        with self.assertRaises(ValueError):check(x)

    def test_wrong_logits_recomputed_final_fingerprint(self):
        x=fresh();execution(x,1)['finalDigest']['finalLogits']['logicalBytesSHA256']='1'*64;restate(x,1)
        with self.assertRaises(ValueError):check(x)

    def test_coherent_arithmetic_environment_change(self):
        x=fresh();a=dep.context()[0]
        for rows in x['ranks']:
            report=rows[1];report['arithmeticEnvironment']=copy.deepcopy(report['arithmeticEnvironment'])
            report['arithmeticEnvironment']['contract']='changed_tf32_contract'
            report['arithmeticEnvironmentSHA256']=a.sha(a.canonical(report['arithmeticEnvironment']))
        with self.assertRaises(ValueError):check(x)

    def test_source_bound_opaque_payload_limit(self):
        x=fresh();rewrite_frame(x,15,lambda obj:obj['boundary'].update(payloadSHA256='1'*64))
        # Both endpoints, token and wire commitments can be coherently fabricated;
        # numerical payload bytes are not exported, so this cannot be disproved.
        r=check(x);self.assertEqual(r['frames'][-1]['payloadSHA256'],'1'*64)
        self.assertFalse(r['candidateNativeBytesIndependentlyReconstructed'])

    def test_complete_file_api_with_fabricated_baseline_pin(self):
        x=fresh();a=dep.context()[0]
        with tempfile.TemporaryDirectory(prefix='rank-audit-fake-') as temp:
            d=Path(temp);paths=[d/'rank0.jsonl',d/'rank1.jsonl']
            for p,rows in zip(paths,x['ranks']):p.write_bytes(factory.encoded(rows))
            baseline=factory.encoded(x['baseline']);(d/'reference.jsonl').write_bytes(baseline);(d/'prompt.json').write_bytes(x['prompt'])
            # Patch only the fabricated baseline constant; real receipt/source pins
            # remain verified. This is a file-handling test, never qualification.
            with patch.object(dep,'BASELINE_SHA',a.sha(baseline)):
                r=audit.validate(paths,d/'reference.jsonl',d/'prompt.json',x['promptSHA'],x['epoch'],x['policy'])
                self.assertTrue(r['frozenInputsUnchanged'])
            with self.assertRaisesRegex(ValueError,'Separately frozen'):
                audit.validate(paths,d/'reference.jsonl',d/'prompt.json',x['promptSHA'],x['epoch'],x['policy'])

    def test_duplicate_outer_keys_rejected(self):
        x=fresh();raw=factory.encoded(x['ranks'][0]);raw=raw.replace(b'"rank":0',b'"rank":0,"rank":0',1)
        with self.assertRaises(ValueError):audit.parse_rows(raw)

    def test_excess_or_partial_records_rejected(self):
        raw=factory.encoded(fresh()['ranks'][0])
        for altered in (raw.splitlines()[0],raw+b'{}\n',b'',b'[]\n{}\n',b'{}\n\xff\n'):
            with self.assertRaises((ValueError,UnicodeDecodeError)):audit.parse_rows(altered)

    def test_output_limit_and_depth(self):
        for data in (b' '*audit.MAX_STDOUT+b'X',b'['*20+b'0'+b']'*20+b'\n{}\n'):
            with self.assertRaises(ValueError):audit.parse_rows(data)

    def test_baseline_signed_zero_digest_change_rejected(self):
        x=fresh();x['baseline']=copy.deepcopy(x['baseline']);x['baseline'][1]['evidence']['execution']['finalLogits']['values'][0]=0.0
        with self.assertRaises(ValueError):check(x)


def mutate(name, operation, policy='serial_v1'):
    def test(self):
        x=fresh(policy);operation(x)
        with self.assertRaises(ValueError,msg=name):check(x)
    setattr(RankAuditTests,'test_reject_'+name,test)


mutate('duplicate_rank',lambda x:x['ranks'][1][1].update(rank=0))
mutate('ready_not_completed',lambda x:x['ranks'][0][0].update(modelsReadyAgreementValidated=False))
mutate('rank_ready_future_state',lambda x:x['ranks'][0][0].update(freshRequestStateCreated=True))
mutate('legacy_envelope_outer',lambda x:x['ranks'][0][1].update(envelopeVersion=3))
mutate('coherent_raw_prompt_wrong_pin',lambda x:x.update(prompt=x['prompt']+b' '))
mutate('wrong_source_mapping',lambda x:x['ranks'][0][1]['sourceLoad']['activeTensors'][0].update(localName='lm_head.weight'))
mutate('boolean_tensor_shape',lambda x:x['ranks'][0][1]['sourceLoad']['activeTensors'][0]['shape'].__setitem__(0,True))
mutate('inert_parameter_bytes',lambda x:x['ranks'][0][1]['sourceLoad']['inertModules'][0]['parameters'][0].update(byteCount=0))
mutate('no_source_policy',lambda x:x['ranks'][0][1]['sourceLoad'].update(bf16ConversionEnabled=False))
mutate('stale65_request',lambda x:x['ranks'][0][1]['request']['request'].update(promptCount=65,chunkSize=32))
mutate('teacher_token',lambda x:x['ranks'][0][1]['request'].update(teacherTokenIDs=[271]))
mutate('changed_token_history',lambda x:x['ranks'][1][1]['request']['promptTokenIDs'].__setitem__(0,99))
mutate('wrong_request_id',lambda x:x['ranks'][1][1]['request']['request'].update(requestID='0'*32))
mutate('duplicate_state_owner',lambda x:execution(x)['finalDigest']['finalState']['entries'].__setitem__(1,copy.deepcopy(execution(x)['finalDigest']['finalState']['entries'][0])))
mutate('wrong_state_shape',lambda x:execution(x)['finalDigest']['finalState']['entries'][0]['shape'].__setitem__(-1,4097))
mutate('wrong_state_dtype',lambda x:execution(x)['finalDigest']['finalState']['entries'][0].update(dtype='float32'))
mutate('omitted_state',lambda x:execution(x)['finalDigest']['finalState']['entries'].pop())
mutate('invented_candidate_values',lambda x:execution(x,1)['finalDigest']['finalLogits'].update(values=[0]))
mutate('candidate_claims_native_exact',lambda x:execution(x,1)['finalDigest'].update(nativeLogitBytesCompared=True))
mutate('rank1_logit_shape',lambda x:execution(x,1)['finalDigest']['finalLogits'].update(shape=[248320]))
mutate('intermediate_capture',lambda x:execution(x)['finalDigest'].update(perFrameStateCaptures=16))
mutate('wrong_tie_choice',lambda x:rewrite_token(x,lambda p:p.update(tokenID=109)))
mutate('token_boolean_id',lambda x:rewrite_token(x,lambda p:p.update(tokenID=True)))
mutate('token_float_ordinal',lambda x:rewrite_token(x,lambda p:p.update(tokenOrdinal=0.0)))
mutate('token_epoch_replay',lambda x:rewrite_token(x,lambda p:p.update(epoch='0'*32)))
mutate('token_stale_flow',lambda x:rewrite_token(x,lambda p:p.update(flow='bounded_prefill_measurement_v1')))
mutate('token_wrong_final_raw_sha',lambda x:rewrite_token(x,lambda p:p.update(finalBoundaryWireBytesSHA256=p['finalBoundaryEnvelopeFingerprint'])))
mutate('local_selection_wrong',lambda x:execution(x,1)['localSelection'].update(tokenID=109))
mutate('fractional_inner_header_version',lambda x:rewrite_frame(x,0,lambda p:p['boundary'].update(version=2.0)))
mutate('nested_boolean_frame_integer',lambda x:rewrite_frame(x,0,lambda p:p['boundary']['frame'].update(sequence=False)))
mutate('coherent_inner_token_hash',lambda x:rewrite_frame(x,0,lambda p:p['boundary'].update(tokenIDsSHA256='1'*64)))
mutate('coherent_payload_shape',lambda x:rewrite_frame(x,0,lambda p:p['boundary'].update(shape=[1,256,8192])))
mutate('coherent_boundary_replay',lambda x:rewrite_frame(x,0,lambda p:p['boundary']['frame'].update(tokenOffset=512)))
mutate('crossrank_payload_hash',lambda x:execution(x,1)['frames'][0].update(envelopeWireBytesSHA256='1'*64))
mutate('domain_swapped_with_raw',lambda x:execution(x)['frames'][0].update(envelopeFingerprint=execution(x)['frames'][0]['envelopeWireBytesSHA256']))
mutate('missing_frame',lambda x:execution(x)['frames'].pop())
mutate('incorrect_native_commit',lambda x:execution(x,1)['frames'][0]['commit'].update(committedTokens=1024))
mutate('duplicate_nested_json_key',lambda x:execution(x)['frames'][0].update(exactEnvelopeJSON=execution(x)['frames'][0]['exactEnvelopeJSON'].replace('"version":2','"version":2,"version":2')))
mutate('noncanonical_source_bytes',lambda x:execution(x)['frames'][0].update(exactEnvelopeJSON=' '+execution(x)['frames'][0]['exactEnvelopeJSON']))
mutate('missing_action',lambda x:execution(x)['actions'].pop())
mutate('boolean_counter',lambda x:execution(x)['actions'][0].update(completedBoundaryCount=False))
mutate('before_release_prepare',lambda x:phase(x,'producerBoundaryReleased').update(explicitPreparedBoundarySlots=1))
mutate('early_consumed_counter',lambda x:phase(x,'send.receivedACKAccepted').update(completedBoundaryCount=1))
mutate('receiver_preconsume_advanced',lambda x:phase(x,'receive.beginConsumption',1).update(nativeCommittedTokens=512))
mutate('receiver_consumed_before_release',lambda x:phase(x,'receive.consumedBoundaryReleased',1).update(completedBoundaryCount=1))
mutate('serial_lookahead_frontier',lambda x:phase(x,'send.beginConsumedDrain').update(nativeCommittedTokens=1024))
mutate('lookahead_serial_actions',lambda x:execution(x).update(actions=factory.actions(0,'serial_v1')),policy='prompt_lookahead_one_v1')
mutate('stop_before_token',lambda x:phase(x,'control.tokenValidated').update(action='firstTokenStopRecorded'))
mutate('diagnostics_before_poststop',lambda x:phase(x,'control.postStopSendCompleted').update(action='postStopDiagnostics.begin'))
mutate('unreleased_boundary',lambda x:execution(x).update(releasedOriginalBoundaryHandles=15))
mutate('pending_retirement',lambda x:execution(x).update(allRequestStateRetired=False))
mutate('live_model',lambda x:x['ranks'][1][1].update(modelReleased=False))
mutate('claimed_physical',lambda x:x['ranks'][1][1].update(physicalTransferQualified=True))
mutate('claimed_throughput',lambda x:execution(x).update(throughputMeasurementValid=True))
mutate('extra_receiver_timing',lambda x:execution(x,1).update(timing=copy.deepcopy(execution(x)['timing'])))
mutate('extra_sender_selection',lambda x:execution(x).update(localSelection=copy.deepcopy(execution(x,1)['localSelection'])))
mutate('wrong_timing_inclusions',lambda x:execution(x)['timing'].update(includesFinalDiagnosticCaptures=True))
mutate('zero_elapsed',lambda x:execution(x)['timing'].update(elapsedNanoseconds=0))
mutate('negative_time',lambda x:execution(x)['timing'].update(startUptimeNanoseconds=-1))
mutate('boolean_time',lambda x:execution(x)['timing'].update(startUptimeNanoseconds=True))
mutate('overflow_time',lambda x:execution(x)['timing'].update(stopUptimeNanoseconds=2**64))
mutate('postclose_overflow',lambda x:execution(x)['timing'].update(postStopThroughRequestCloseNanoseconds=2**64-1))
mutate('nonfinite_rate',lambda x:execution(x)['timing'].update(promptTokensPerFirstTokenSecond=float('nan')))
mutate('wrong_rate',lambda x:execution(x)['timing'].update(promptTokensPerFirstTokenSecond=8192.0))
mutate('elapsed_arithmetic',lambda x:execution(x)['timing'].update(elapsedNanoseconds=1))
mutate('cache_not_cleared',lambda x:x['ranks'][0][1]['memory'][-1].update(cachedMLXBytes=4))
mutate('false_allocator_peak',lambda x:x['ranks'][0][1]['memory'][-1].update(peakMLXBytesSinceProcessStart=0))


if __name__=='__main__':unittest.main(verbosity=2)
