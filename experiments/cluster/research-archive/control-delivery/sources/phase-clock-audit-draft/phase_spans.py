"""Local marker intervals. These include CPU work, synchronization and observers."""
import phase_contract as c


def summaries(events,role,clock):
    lookup={(e['phase'],e.get('frameSequence')):e for e in events}
    c.require(len(lookup)==len(events),'Duplicate phase/frame observation')
    groups=[]
    def event(phase,frame=None):return lookup[(phase,frame)]
    def interval(start,end,frame=None):
        a=event(start,frame);b=event(end,frame)
        c.require(a['ordinal']<b['ordinal'],'Interval marker order differs')
        value=dict(startPhase=start,endPhase=end,startOrdinal=a['ordinal'],endOrdinal=b['ordinal'],
            elapsedNanoseconds=b['localUptimeNanoseconds']-a['localUptimeNanoseconds'])
        if frame is not None:value['frameSequence']=frame
        return value
    def group(name,pairs,per_frame=False):
        spans=[interval(a,b,i) for i in range(16) for a,b in pairs] if per_frame else [interval(a,b) for a,b in pairs]
        ordered=sorted(spans,key=lambda x:x['startOrdinal'])
        c.require(all(a['endOrdinal']<=b['startOrdinal'] for a,b in zip(ordered,ordered[1:])),
            'Selected interval group overlaps')
        total=sum(x['elapsedNanoseconds'] for x in spans)
        c.require(0<=total<=events[-1]['localUptimeNanoseconds']-events[0]['localUptimeNanoseconds'],'Local interval total exceeds trace')
        groups.append(dict(name=name,intervalCount=len(spans),totalNanoseconds=total,intervals=spans))
    def time(phase):return event(phase)['localUptimeNanoseconds']
    if role=='solo':
        c.require(time('freshRequest.begin')<=clock['start']<=time('freshRequest.created'),'Solo start marker enclosure differs')
        c.require(time('selection.begin')<=clock['stop']<=time('selection.completed'),'Solo stop marker enclosure differs')
        c.require(time('retirement.begin')<=clock['closed']<=time('request.closed'),'Solo close marker enclosure differs')
        group('prefill_chunks_cpu_observed',[('prefill.begin','prefill.committed')],True)
        group('fresh_request_cpu_observed',[('freshRequest.begin','freshRequest.created')])
        group('finite_selection_cpu_observed',[('selection.begin','selection.completed')])
        group('final_diagnostics_cpu_observed',[('diagnostics.begin','diagnostics.completed')])
        group('retirement_cpu_observed',[('retirement.begin','request.closed')])
    else:
        group('preclock_readiness_cpu_observed',[('readiness.begin','readiness.completed')])
        if role=='rank0':
            c.require(time('readiness.completed')<=clock['start']<=time('control.beginStartSend'),'Rank0 start marker enclosure differs')
            c.require(time('control.tokenValidated')<=clock['stop']<=time('firstTokenStopRecorded'),'Rank0 stop marker enclosure differs')
            c.require(time('requestClosed')<=clock['closed'],'Rank0 close timestamp precedes observed close action')
            group('stage0_prepare_cpu_observed',[('prepare.begin','prepare.committed')],True)
            for label,a,b in [('header_send','beginHeader','headerSendCompleted'),
                ('ready_wait_validation','headerSendCompleted','readyACKAccepted'),
                ('payload_send','beginPayloadSend','payloadSendCompleted'),
                ('received_wait_validation','payloadSendCompleted','receivedACKAccepted'),
                ('consumed_drain_wait_validation','beginConsumedDrain','consumedACKAccepted')]:
                group(label+'_cpu_observed',[('send.'+a,'send.'+b)],True)
            controls=[('beginStartSend','startSendCompleted'),('beginTokenReceive','tokenValidated'),('beginPostStopSend','postStopSendCompleted')]
        else:
            c.require(clock is None,'Rank1 must not acquire a main origin clock')
            group('stage1_consume_and_final_selection_cpu_observed',
                [('receive.beginConsumption','receive.consumptionAndSelectionValidated')],True)
            for label,a,b in [('header_receive_validation','beginHeaderReceive','headerValidated'),
                ('ready_ack_send','beginReadyACK','readyACKSendCompleted'),
                ('payload_receive_validation','beginPayloadReceive','payloadReceivedAndValidated'),
                ('received_ack_send','beginReceivedACK','receivedACKSendCompleted'),
                ('consumed_ack_send','beginConsumedACK','consumedACKSendCompleted')]:
                group(label+'_cpu_observed',[('receive.'+a,'receive.'+b)],True)
            controls=[('beginStartReceive','startValidated'),('beginTokenSend','tokenSendCompleted'),('beginPostStopReceive','postStopValidated')]
        group('control_transfers_cpu_observed',[('control.'+a,'control.'+b) for a,b in controls])
        group('final_diagnostics_and_retirement_cpu_observed',[('postStopDiagnostics.begin','requestClosed')])
    # All reported intervals are disjoint even across groups; uncovered time is not classified.
    spans=sorted([x for g in groups for x in g['intervals']],key=lambda x:x['startOrdinal'])
    c.require(all(a['endOrdinal']<=b['startOrdinal'] for a,b in zip(spans,spans[1:])),
        'Summary groups double count an observed interval')
    return groups
