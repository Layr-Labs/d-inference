"""Pure source-derived v4 rank action order; no clock, file IO or native work."""

POLICIES = ('serial_v1', 'prompt_lookahead_one_v1')


def expected_actions(rank, policy):
    if rank not in (0, 1) or policy not in POLICIES:
        raise ValueError('Invalid admitted rank/policy')
    rows=[];tokens=0;completed=0;prepared=0;pending=0
    def event(name, frame=None):
        x=dict(ordinal=len(rows),action=name,nativeCommittedTokens=tokens,
            completedBoundaryCount=completed,explicitPreparedBoundarySlots=prepared,
            pendingConsumedFrameSlots=pending)
        if frame is not None:x['frameSequence']=frame
        rows.append(x)
    def prepare(index):
        nonlocal tokens,prepared
        event('prepare.begin',index);tokens=(index+1)*512;prepared=1
        event('prepare.committed',index)
    event('readiness.begin');event('readiness.completed')
    for name in (['beginStartSend','startSendCompleted'] if rank==0 else ['beginStartReceive','startValidated']):
        event('control.'+name)
    event('freshContextCreated')
    for index in range(16):
        if rank==0:
            if not prepared:prepare(index)
            for name in ['beginHeader','headerSendCompleted','readyACKAccepted','beginPayloadSend','payloadSendCompleted']:
                event('send.'+name,index)
            pending=1;event('send.receivedACKAccepted',index)
            prepared=0;event('producerBoundaryReleased',index)
            if policy=='prompt_lookahead_one_v1' and index<15:prepare(index+1)
            event('send.beginConsumedDrain',index)
            pending=0;completed+=1;event('send.consumedACKAccepted',index)
        else:
            for name in ['beginHeaderReceive','headerValidated','beginReadyACK','readyACKSendCompleted',
                'beginPayloadReceive','payloadReceivedAndValidated','beginReceivedACK','receivedACKSendCompleted','beginConsumption']:
                event('receive.'+name,index)
            tokens=(index+1)*512
            for name in ['consumptionAndSelectionValidated','consumedBoundaryReleased','beginConsumedACK']:
                event('receive.'+name,index)
            completed+=1;event('receive.consumedACKSendCompleted',index)
        event('frameCompleted',index)
    for name in (['beginTokenReceive','tokenValidated'] if rank==0 else ['beginTokenSend','tokenSendCompleted']):
        event('control.'+name)
    if rank==0:event('firstTokenStopRecorded')
    for name in (['beginPostStopSend','postStopSendCompleted'] if rank==0 else ['beginPostStopReceive','postStopValidated']):
        event('control.'+name)
    event('postStopDiagnostics.begin');event('requestClosed')
    if len(rows)!=(204 if rank==0 else 235):raise ValueError('Source-derived timeline count differs')
    return rows


def timing_flags():
    return dict(clock='DispatchTime.uptimeNanoseconds_rank_zero_only',
        startEvent='before_start_send_and_fresh_context_creation',
        stopEvent='after_final_consumed_and_selected_token_validation',diagnosticOnly=True,
        includesModelLoading=False,includesPreparedTokenDistribution=False,includesReadinessExchange=False,
        includesFreshRequestState=True,includesFreshContextAdmission=True,includesBoundaryValidationAndCopies=True,
        includesScalarTraceRecording=True,includesFinalTokenSelectionAndReturn=True,includesFinalDiagnosticCaptures=False,
        includesPostStopAcknowledgement=False,includesRequestRetirement=False)


