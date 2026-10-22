"""Prospective CPU-only rank fixtures. No future rank-mode native run is claimed."""
import copy
import hashlib
import json
from pathlib import Path
import tempfile
import unittest

import qwen_layer_stage_prefill_rank_audit as audit

ROOT = Path(__file__).parent
REFERENCE = ROOT / 'runs/qwen-layer-stage-prefill-peer24-20260914/native/stdout.jsonl'
EXPECTED = ROOT / 'qwen-layer-stage-real9b-expected-20260913.json'
EPOCH = 'ad9cd670df604a5e9392e32a6c968cb3'


def encoded(value): return json.dumps(value, sort_keys=True, separators=(',', ':'))
def sha(text): return hashlib.sha256(text.encode()).hexdigest()


def fixture_trace(rank, lookahead):
    """Build serial templates; move each later prepare pair for lookahead."""
    out = []
    def event(name, frontier, completed, frame=None, prepared=0, pending=0):
        value = dict(ordinal=0, action=name, nativeCommittedTokens=frontier, completedBoundaryCount=completed,
            explicitPreparedBoundarySlots=prepared, pendingConsumedFrameSlots=pending)
        if frame is not None: value['frameSequence'] = frame
        out.append(value)
    if rank == 0:
        for name in ['control.beginStartSend', 'control.startSendCompleted', 'freshContextCreated']: event(name, 0, 0)
        for sequence, (before, after) in enumerate([(0,32),(32,64),(64,65)]):
            event('prepare.begin', before, sequence, sequence)
            event('prepare.committed', after, sequence, sequence, prepared=1)
            for name in ['beginHeader','headerSendCompleted','readyACKAccepted','beginPayloadSend','payloadSendCompleted']:
                event('send.'+name, after, sequence, sequence, prepared=1)
            event('send.receivedACKAccepted', after, sequence, sequence, prepared=1, pending=1)
            event('producerBoundaryReleased', after, sequence, sequence, pending=1)
            event('send.beginConsumedDrain', after, sequence, sequence, pending=1)
            event('send.consumedACKAccepted', after, sequence+1, sequence)
            event('frameCompleted', after, sequence+1, sequence)
        if lookahead:
            for sequence in [1,2]:
                moved = [x for x in out if x['action'].startswith('prepare.') and x.get('frameSequence') == sequence]
                out[:] = [x for x in out if x not in moved]
                where = next(i for i,x in enumerate(out) if x['action']=='producerBoundaryReleased' and x['frameSequence']==sequence-1)+1
                for item in moved:
                    item['completedBoundaryCount'] = sequence-1; item['pendingConsumedFrameSlots'] = 1
                out[where:where] = moved
                for item in out:
                    if item.get('frameSequence') == sequence-1 and item['action'] in ['send.beginConsumedDrain','send.consumedACKAccepted','frameCompleted']:
                        item['nativeCommittedTokens'] = [32,64,65][sequence]; item['explicitPreparedBoundarySlots'] = 1
        for name in ['control.beginTokenReceive','control.tokenValidated','firstTokenStopRecorded',
                'control.beginPostStopSend','control.postStopSendCompleted','postStopDiagnostics.begin','requestClosed']:
            event(name,65,3)
    else:
        for name in ['control.beginStartReceive','control.startValidated','freshContextCreated']: event(name,0,0)
        for sequence,(before,after) in enumerate([(0,32),(32,64),(64,65)]):
            for name in ['beginHeaderReceive','headerValidated','beginReadyACK','readyACKSendCompleted',
                    'beginPayloadReceive','payloadReceivedAndValidated','beginReceivedACK','receivedACKSendCompleted','beginConsumption']:
                event('receive.'+name,before,sequence,sequence)
            for name in ['consumptionAndSelectionValidated','consumedBoundaryReleased','beginConsumedACK']:
                event('receive.'+name,after,sequence,sequence)
            event('receive.consumedACKSendCompleted',after,sequence+1,sequence)
            event('frameCompleted',after,sequence+1,sequence)
        for name in ['control.beginTokenSend','control.tokenSendCompleted','control.beginPostStopReceive',
                'control.postStopValidated','postStopDiagnostics.begin','requestClosed']: event(name,65,3)
    for index,item in enumerate(out): item['ordinal'] = index
    return out


def prospective_fixture(reference, policy):
    prefill = audit.prefill_helper(); base = reference[0]['baseline']; loads = reference[1]['stageLoads']
    request = copy.deepcopy(base['request']); request['request']['requestID']='AD9CD670-DF60-4A5E-9392-E32A6C968CB3'
    simple = sha('qwen-stage-request-v1|ad9cd670-df60-4a5e-9392-e32a6c968cb3|65|32|1')
    request['fingerprint']=sha('qwen-layer-stage-recorded-request-v1\n'+simple+'\nvocabulary=248320\nprompt='
        +','.join(map(str,request['promptTokenIDs']))+'\nteacher=')
    first,second=loads
    descriptor=dict(version=3,flow='bounded_prefill_measurement_v1',schedulingPolicy=policy,epoch=EPOCH,
        requestID=request['request']['requestID'].lower(),requestFingerprint=simple,recordedRequestFingerprint=request['fingerprint'],
        promptCount=65,chunkSize=32,outputCount=1,batchSize=1,frameCount=3,
        promptTokenIDsSHA256=sha(','.join(map(str,request['promptTokenIDs']))),
        sourceConfigurationSHA256=first['sourceConfigurationSHA256'],artifactAggregateSHA256=first['verifiedAggregateSHA256'],
        storageCommitmentSHA256=first['storageCommitmentSHA256'],planFingerprint=first['planSHA256'],
        producerStageFingerprint=first['stagePlanSHA256'],consumerStageFingerprint=second['stagePlanSHA256'],
        producerConstructionConfigurationSHA256=first['constructionConfigurationSHA256'],
        consumerConstructionConfigurationSHA256=second['constructionConfigurationSHA256'],bf16ConversionEnabled=True,
        hiddenSize=4096,nativeDType='bfloat16',logitsDType='bfloat16',vocabularySize=248320,
        selectionPolicy='mlx_argmax_all_axes_with_finite_guard_v1')
    agreement=sha('qwen-prefill-start-agreement-v1\n'+encoded(descriptor))
    identities=[prefill.session_identity(load,rank,simple) for rank,load in enumerate(loads)]
    envelopes=[]
    for index,step in enumerate(request['steps']):
        h=dict(version=1,requestFingerprint=simple,sourceConfigurationSHA256=first['sourceConfigurationSHA256'],
            artifactAggregateSHA256=first['verifiedAggregateSHA256'],storageCommitmentSHA256=first['storageCommitmentSHA256'],
            planFingerprint=first['planSHA256'],producerStageFingerprint=first['stagePlanSHA256'],frame=step['frame'],
            tokenIDsSHA256=sha(','.join(map(str,step['tokenIDs']))),payloadSHA256=sha('fabricated CPU fixture residual '+str(index)),
            shape=[1,step['frame']['tokenCount'],4096],dtype='bfloat16',byteCount=step['frame']['tokenCount']*8192)
        envelopes.append(encoded(dict(version=3,flow=audit.FLOW,kind='boundary',agreementFingerprint=agreement,boundary=h)))
    packet=encoded(dict(version=3,flow=audit.FLOW,kind='first_selected_token',agreementFingerprint=agreement,epoch=EPOCH,
        requestFingerprint=simple,recordedRequestFingerprint=request['fingerprint'],consumerStageFingerprint=second['stagePlanSHA256'],
        finalBoundaryEnvelopeSHA256=sha(envelopes[2]),frame=request['steps'][2]['frame'],committedTokens=65,vocabularySize=248320,
        tokenOrdinal=0,selectionPolicy=audit.SELECTION,tokenID=2526,logitsShape=[1,248320],logitsDType='bfloat16',
        selectionDType='uint32',allLogitsFinite=True))
    ranks=[]
    for rank in range(2):
        common=dict(schemaVersion=1,epoch=EPOCH,rank=rank,worldSize=2,transport='loopback-test',backend='ring',
            flow=audit.FLOW,envelopeVersion=3,agreementFingerprint=agreement,agreement=descriptor)
        ready=dict(kind='qwen_layer_stage_prefill_rank_ready',modelsReadyAgreementValidated=True,freshRequestStateCreated=False,**common)
        frames=[]
        for index,step in enumerate(request['steps']):
            kind='hidden' if rank==0 else ('logits' if index==2 else 'evaluation_handle')
            shape=[1,step['frame']['tokenCount'],4096] if rank==0 else ([1,248320] if index==2 else [1,1])
            commit=dict(identity=identities[rank],recordedRequestFingerprint=request['fingerprint'],frame=step['frame'],
                committedTokens=[32,64,65][index],outputKind=kind,outputShape=shape,outputDType='bfloat16')
            frames.append(dict(commit=commit,exactEnvelopeJSON=envelopes[index],envelopeSHA256=sha(envelopes[index])))
        entries=[e for e in base['frames'][2]['state']['entries'] if rank*16<=e['globalLayerIndex']<(rank+1)*16]
        execution=dict(kind='qwen_layer_stage_prefill_rank_request',agreementFingerprint=agreement,identity=identities[rank],
            frames=frames,actions=fixture_trace(rank,policy=='prompt_lookahead_one_v1'),selectedTokenID=2526,
            exactTokenPacketJSON=packet,tokenPacketSHA256=sha(packet),finalStateEntries=entries,
            finalStateLogicalBytes=sum(e['byteCount'] for e in entries),finalStateSHA256=prefill.state_hash(entries,65),
            completedFrames=3,committedTokens=65,preparedAheadFrames=2 if rank==0 and policy=='prompt_lookahead_one_v1' else 0,
            releasedOriginalBoundaryHandles=3,perFrameStateSnapshots=0,perFrameLogitCaptures=0,finalStateSnapshots=1,
            finalLogitCaptures=rank,localTokenSelections=rank,postStopReleaseCompleted=True,allRequestStateRetired=True)
        if rank==0:
            execution['timing']=dict(clock='DispatchTime.uptimeNanoseconds_rank_zero_only',
                startEvent='before_start_send_and_fresh_context_creation',stopEvent='after_final_consumed_and_selected_token_validation',
                diagnosticOnly=True,startUptimeNanoseconds=1000000000000,stopUptimeNanoseconds=1002000000000,
                elapsedNanoseconds=2000000000,promptTokensPerFirstTokenSecond=32.5,postStopThroughRequestCloseNanoseconds=100000000,
                includesModelLoading=False,includesPreparedTokenDistribution=False,includesFreshRequestState=True,
                includesBoundaryValidationAndCopies=True,includesScalarTraceRecording=True,includesFinalTokenSelectionAndReturn=True,
                includesFinalDiagnosticCaptures=False,includesPostStopAcknowledgement=False,includesRequestRetirement=False)
        else:
            for key in ['localSelection','finalLogits']:
                value=copy.deepcopy(reference[1]['comparison']['token' if key=='localSelection' else 'finalLogits'])
                value.update(identity=identities[1],recordedRequestFingerprint=request['fingerprint'])
                execution[key]=value
        memory=copy.deepcopy([reference[1]['memory'][i] for i in [0,2,3,4]])
        for observation,phase in zip(memory,['before_stage_load','stage_loaded_no_request_state',
                'stage_request_retired_weights_resident','stage_model_released_cache_cleared']): observation['phase']=phase
        report=dict(kind='qwen_layer_stage_prefill_rank_report',completed=True,correctnessOnly=True,throughputMeasurementValid=False,
            modelForwardCompared=False,physicalTransferQualified=False,sourceLoad=loads[rank],request=request,execution=execution,
            allRequestStateRetired=True,modelReleased=True,conservativeStateAndBoundaryBytes=reference[1]['conservativeStateAndBoundaryBytes'],
            memory=memory,**common)
        ranks.append([ready,report])
    # Remove fixture-only aliases, preserving a complete independent rank pair.
    return json.loads(json.dumps(ranks))


class PrefillRankAuditTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.reference,pin=audit.prefill_helper().read_rows(REFERENCE); assert pin==audit.REFERENCE_SHA
        cls.expected=json.loads(EXPECTED.read_text())
        cls.fixtures={policy:prospective_fixture(cls.reference,policy) for policy in audit.POLICIES}

    def check(self,rows=None,policy='serial_v1'):
        return audit.validate_reports(rows or self.fixtures[policy],self.reference,self.expected,EPOCH,policy)

    def reject(self,mutate,policy='serial_v1'):
        rows=copy.deepcopy(self.fixtures[policy]); mutate(rows)
        with self.assertRaises(ValueError): self.check(rows,policy)

    def test_both_prospective_policies(self):
        for policy in audit.POLICIES:
            r=self.check(policy=policy)
            self.assertEqual(r['actionCounts'],[46,51]); self.assertEqual(r['argmaxTokenID'],2526)
            self.assertEqual(r['independentlyReconstructedCandidateLogitRows'],0)
            self.assertFalse(r['currentRankNativePrivateByteComparisonReported']); self.assertFalse(r['throughputQualified'])

    def test_file_api_prospective(self):
        with tempfile.TemporaryDirectory() as tmp:
            paths=[]
            for rank,rows in enumerate(self.fixtures['serial_v1']):
                path=Path(tmp)/f'rank{rank}.jsonl';path.write_text('\n'.join(json.dumps(row) for row in rows)+'\n');paths.append(path)
            r=audit.validate(paths,REFERENCE,EXPECTED,EPOCH,'serial_v1');self.assertEqual(r['referenceStdoutSHA256'],audit.REFERENCE_SHA)

    def test_different_epoch(self):
        with self.assertRaises(ValueError): audit.validate_reports(self.fixtures['serial_v1'],self.reference,self.expected,'1'*32,'serial_v1')

    def test_replayed_rank(self): self.reject(lambda r:r.__setitem__(1,r[0]))
    def test_ready_not_complete(self): self.reject(lambda r:r[0].pop())
    def test_model_release_false(self): self.reject(lambda r:r[1][1].update(modelReleased=False))
    def test_state_retirement_false(self): self.reject(lambda r:r[1][1]['execution'].update(allRequestStateRetired=False))
    def test_post_stop_not_complete(self): self.reject(lambda r:r[0][1]['execution'].update(postStopReleaseCompleted=False))
    def test_throughput_claim(self): self.reject(lambda r:r[0][1].update(throughputMeasurementValid=True))
    def test_fresh_state_created_before_ready(self): self.reject(lambda r:r[0][0].update(freshRequestStateCreated=True))
    def test_wrong_source_tensor_owner(self): self.reject(lambda r:r[1][1]['sourceLoad']['activeTensors'][0].update(sourceName='language_model.model.layers.0.linear_attn.A_log'))
    def test_wrong_inert_dtype(self): self.reject(lambda r:r[0][1]['sourceLoad']['inertModules'][0]['parameters'][0].update(dtype='float32'))
    def test_wrong_retained_source_count(self): self.reject(lambda r:r[0][1]['sourceLoad']['storageCommitment'].update(sourceTensorCount=1291))
    def test_wrong_prompt(self): self.reject(lambda r:r[0][1]['request']['promptTokenIDs'].__setitem__(0,1))
    def test_teacher_not_admitted(self): self.reject(lambda r:r[1][1]['request'].update(teacherTokenIDs=[4087]))
    def test_agreement_fractional_integer(self): self.reject(lambda r:r[1][1]['agreement'].update(outputCount=1.0))
    def test_agreement_wrong_logit_dtype(self): self.reject(lambda r:r[0][0]['agreement'].update(logitsDType='float32'))
    def test_wrong_rank_commit_frontier(self): self.reject(lambda r:r[1][1]['execution']['frames'][1]['commit'].update(committedTokens=65))
    def test_reduced_hidden_width(self): self.reject(lambda r:r[0][1]['execution']['frames'][0]['commit'].update(outputShape=[1,32,2048]))
    def test_candidate_raw_values_not_exported(self): self.reject(lambda r:r[1][1]['execution']['finalLogits'].update(values=[0]))
    def test_unmade_native_byte_assertion_not_accepted(self): self.reject(lambda r:r[1][1]['execution'].update(nativeLogitBytesExact=True))
    def test_wrong_logit_digest(self): self.reject(lambda r:r[1][1]['execution']['finalLogits'].update(logicalBytesSHA256='f'*64))
    def test_false_finite_selection(self): self.reject(lambda r:r[1][1]['execution']['localSelection'].update(allLogitsFinite=False))
    def test_per_frame_capture_claim(self): self.reject(lambda r:r[1][1]['execution'].update(perFrameStateSnapshots=3))
    def test_omitted_final_component(self): self.reject(lambda r:r[1][1]['execution']['finalStateEntries'].pop())
    def test_duplicate_global_state_owner(self): self.reject(lambda r:r[1][1]['execution']['finalStateEntries'][0].update(globalLayerIndex=0))
    def test_coherent_final_state_digest_tamper(self):
        def mutate(r):
            x=r[0][1]['execution'];x['finalStateEntries'][0]['sha256']='f'*64
            x['finalStateSHA256']=audit.prefill_helper().state_hash(x['finalStateEntries'],65)
        self.reject(mutate)

    def test_coherent_wrong_token_packet(self):
        def mutate(r):
            for rows in r:
                x=rows[1]['execution'];p=json.loads(x['exactTokenPacketJSON']);p['tokenID']=4087
                x.update(exactTokenPacketJSON=encoded(p),tokenPacketSHA256=sha(encoded(p)),selectedTokenID=4087)
            r[1][1]['execution']['localSelection']['tokenID']=4087
        self.reject(mutate)

    def test_cross_rank_payload_sha_mismatch(self):
        def mutate(r):
            f=r[1][1]['execution']['frames'][0];p=json.loads(f['exactEnvelopeJSON']);p['boundary']['payloadSHA256']='f'*64
            f.update(exactEnvelopeJSON=encoded(p),envelopeSHA256=sha(encoded(p)))
        self.reject(mutate)

    def test_original_nested_fraction(self):
        def mutate(r):
            f=r[0][1]['execution']['frames'][0];f['exactEnvelopeJSON']=f['exactEnvelopeJSON'].replace('"tokenCount":32','"tokenCount":32.0')
            f['envelopeSHA256']=sha(f['exactEnvelopeJSON'])
        self.reject(mutate)

    def test_original_escaped_duplicate(self):
        def mutate(r):
            f=r[0][1]['execution']['frames'][0];f['exactEnvelopeJSON']='{"\\u0076ersion":3,'+f['exactEnvelopeJSON'][1:]
            f['envelopeSHA256']=sha(f['exactEnvelopeJSON'])
        self.reject(mutate)

    def test_noncanonical_sender_bytes(self):
        def mutate(r):
            for rows in r:
                f=rows[1]['execution']['frames'][0];f['exactEnvelopeJSON']=' '+f['exactEnvelopeJSON'];f['envelopeSHA256']=sha(f['exactEnvelopeJSON'])
        self.reject(mutate)

    def test_wrong_token_packet_final_frame(self):
        def mutate(r):
            x=r[0][1]['execution'];p=json.loads(x['exactTokenPacketJSON']);p['frame']['sequence']=0
            x.update(exactTokenPacketJSON=encoded(p),tokenPacketSHA256=sha(encoded(p)))
        self.reject(mutate)

    def test_wrong_policy_trace(self):
        self.reject(lambda r:r[0][1]['execution'].update(actions=fixture_trace(0,False)),policy='prompt_lookahead_one_v1')

    def test_missing_release_with_renumbered_trace(self):
        def mutate(r):
            a=r[0][1]['execution']['actions'];a[:]=[x for x in a if not(x['action']=='producerBoundaryReleased' and x.get('frameSequence')==0)]
            for i,x in enumerate(a):x['ordinal']=i
        self.reject(mutate)

    def test_false_lookahead_counter(self): self.reject(lambda r:r[0][1]['execution'].update(preparedAheadFrames=0),policy='prompt_lookahead_one_v1')
    def test_false_pending_slot(self):
        def mutate(r):
            x=next(x for x in r[0][1]['execution']['actions'] if x['action']=='send.receivedACKAccepted');x['pendingConsumedFrameSlots']=0
        self.reject(mutate)

    def test_stop_before_token_validation(self):
        def mutate(r):
            a=r[0][1]['execution']['actions'];i=next(i for i,x in enumerate(a) if x['action']=='firstTokenStopRecorded')
            a[i-1],a[i]=a[i],a[i-1]
            for j,x in enumerate(a):x['ordinal']=j
        self.reject(mutate)

    def test_diagnostics_before_post_stop(self):
        def mutate(r):
            a=r[1][1]['execution']['actions'];i=next(i for i,x in enumerate(a) if x['action']=='postStopDiagnostics.begin')
            a[i-1],a[i]=a[i],a[i-1]
            for j,x in enumerate(a):x['ordinal']=j
        self.reject(mutate)

    def test_rank_one_timing_forbidden(self): self.reject(lambda r:r[1][1]['execution'].update(timing=r[0][1]['execution']['timing']))
    def test_reversed_clock(self): self.reject(lambda r:r[0][1]['execution']['timing'].update(stopUptimeNanoseconds=1))
    def test_wrong_duration(self): self.reject(lambda r:r[0][1]['execution']['timing'].update(elapsedNanoseconds=1))
    def test_fractional_nanoseconds(self): self.reject(lambda r:r[0][1]['execution']['timing'].update(elapsedNanoseconds=2000000000.0))
    def test_wrong_rate(self): self.reject(lambda r:r[0][1]['execution']['timing'].update(promptTokensPerFirstTokenSecond=33.0))
    def test_nonfinite_rate(self): self.reject(lambda r:r[0][1]['execution']['timing'].update(promptTokensPerFirstTokenSecond=float('nan')))
    def test_post_stop_overflow(self): self.reject(lambda r:r[0][1]['execution']['timing'].update(postStopThroughRequestCloseNanoseconds=2**64))
    def test_timing_scope_changed(self): self.reject(lambda r:r[0][1]['execution']['timing'].update(includesFinalDiagnosticCaptures=True))
    def test_final_cache_uncleared(self): self.reject(lambda r:r[1][1]['memory'][-1].update(cachedMLXBytes=1))

    def test_bounded_reader(self):
        with tempfile.TemporaryDirectory() as tmp:
            p=Path(tmp)/'input.jsonl'
            for text in ['{}\n','{}\n{}\n{}\n','{"x":1,"x":2}\n{}\n','{"x":NaN}\n{}\n',
                    '{"x":'+'['*17+'0'+']'*17+'}\n{}\n']:
                p.write_text(text)
                with self.assertRaises(ValueError):audit.read_rank_rows(p)


if __name__=='__main__':unittest.main()
