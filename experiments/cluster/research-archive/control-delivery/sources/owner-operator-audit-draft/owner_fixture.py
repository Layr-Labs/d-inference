"""Fabricated phase metadata only; never reads any native candidate outputs."""
import owner_dependencies as d
import owner_clock_audit as a
MODULES=d.modules(fixture=True)
f=MODULES['phase_fixture']
c=MODULES['phase_contract']


def case(role='solo',policy='serial_v1',origin=10**9,epoch=f.EPOCH):
    rows,full=f.solo(origin=origin,epoch=epoch) if role=='solo' else f.rank(int(role[-1]),policy,origin=origin,epoch=epoch)
    start_name,end_name=a.PARENTS[role]
    start=next(x for x in full['events'] if x['phase']==start_name and x.get('frameSequence')==7)
    end=next(x for x in full['events'] if x['phase']==end_name and x.get('frameSequence')==7)
    assert end['localUptimeNanoseconds']-start['localUptimeNanoseconds']==1000
    events=[dict(ordinal=i,phase=name,tokenCount=512,committedTokens=4096 if i==7 else 3584,
        localUptimeNanoseconds=start['localUptimeNanoseconds']+100*(i+1)) for i,name in enumerate(a.PHASES)]
    trace=dict(kind='qwen_prefill_selected_owner_trace',schemaVersion=1,identity=dict(
        requestFingerprint=full['identity']['requestFingerprint'],profile=c.PROFILE,role=role,
        frameSequence=7,tokenOffset=3584,tokenCount=512,committedFrontier=4096),
        clockSource='DispatchTime.uptimeNanoseconds',maximumEvents=8,events=events,
        firstLocalUptimeNanoseconds=events[0]['localUptimeNanoseconds'],lastLocalUptimeNanoseconds=events[-1]['localUptimeNanoseconds'],
        traceSpanNanoseconds=700,diagnosticOnly=True,includesRecorderOverhead=True,
        evaluationIntervalIncludesExistingErrorCheck=True,crossProcessClockAlignmentAsserted=False,
        gpuKernelTimeAsserted=False,gpuOverlapAsserted=False,modelReleaseAsserted=False,recorderIndependentlyVerifiesOuterSuccess=False)
    return rows,full,trace


def retime(owner,times):
    assert len(times)==8
    for event,time in zip(owner['events'],times):event['localUptimeNanoseconds']=time
    owner['firstLocalUptimeNanoseconds']=times[0];owner['lastLocalUptimeNanoseconds']=times[-1]
    owner['traceSpanNanoseconds']=times[-1]-times[0]
