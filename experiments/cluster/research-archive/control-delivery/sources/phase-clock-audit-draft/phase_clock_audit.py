"""Prospective CPU-only correlation/summarizer for opt-in local phase sidecars.

Run the existing numerical and runtime-provenance audits separately. Passing
this helper does not attest the opaque model fields in the unchanged base JSON.
"""
from pathlib import Path
import json
import sys
import phase_contract as c
import phase_base
import phase_spans

CORE_FILES=['phase_clock_audit.py','phase_contract.py','phase_base.py','phase_spans.py']
TRACE_FIELDS='kind schemaVersion identity clockSource maximumEvents events firstLocalUptimeNanoseconds lastLocalUptimeNanoseconds traceSpanNanoseconds diagnosticOnly includesRecorderOverhead crossProcessClockAlignmentAsserted gpuOverlapAsserted modelReleaseAsserted recorderIndependentlyVerifiesRequestRetirement'
LIMITATIONS=[
 'This supplementary audit checks phase metadata, its recorded request/history, exact source-derived actions and local marker arithmetic. Source tensors, envelope/ACK bytes, final numerical states/logits, native selection, memory and runtime ownership remain the separate frozen numerical and provenance audits\' scope.',
 'The clock-source label and phase placement are source-bound assertions requiring the actual executable/source archive. JSON can be coherently fabricated; this CPU replay does not independently measure native execution or prove that the production clock ran.',
 'Local marker spans include observer overhead, CPU work, synchronization and any scheduling delay. Receiver consumption includes final finite selection. Collective spans include the named transfer/wait and validation; none isolate network, device-kernel or GPU duration.',
 'Clocks are never aligned across ranks or compared between requests. No cross-process critical path, GPU overlap, causal scheduling speedup, representative throughput or physical-transfer claim is made.',
 'Selected intervals are disjoint within each local trace and do not cover every operation. Uncovered time is unclassified. Trace construction/publication, outer model release and cache clear are outside the last request marker; the trace is not independent proof of retirement or model release.'
]


def check_records(rows,trace,role):
    """Pure dict API, for synthetic tests as well as parsed saved records."""
    identity=phase_base.base(rows,role)
    c.fields(trace,TRACE_FIELDS,'phase trace')
    c.flags(trace,kind='qwen_prefill_local_phase_trace',schemaVersion=1,clockSource='DispatchTime.uptimeNanoseconds',maximumEvents=512,
        diagnosticOnly=True,includesRecorderOverhead=True,crossProcessClockAlignmentAsserted=False,gpuOverlapAsserted=False,
        modelReleaseAsserted=False,recorderIndependentlyVerifiesRequestRetirement=False)
    c.exact(trace['identity'],dict(requestFingerprint=identity['recordedRequestFingerprint'],profile=c.PROFILE,role=role),'trace identity')
    events=trace['events'];expected=identity.pop('expectedEvents');clock=identity.pop('primaryClock',None)
    c.require(type(events) is list and len(events)==len(expected)<=trace['maximumEvents'],'Exact bounded event count required')
    previous=0
    for e,wanted in zip(events,expected):
        c.require(type(e) is dict and set(e)==set(wanted)|{'localUptimeNanoseconds'},'Event schema/optional frame differs')
        c.exact({key:e[key] for key in wanted},wanted,'phase event')
        now=c.integer(e['localUptimeNanoseconds']);c.require(now>=previous,'Local uptime reversed');previous=now
    first=c.integer(trace['firstLocalUptimeNanoseconds']);last=c.integer(trace['lastLocalUptimeNanoseconds'])
    span=c.integer(trace['traceSpanNanoseconds'])
    c.require(first==events[0]['localUptimeNanoseconds'] and last==events[-1]['localUptimeNanoseconds']
        and first<=last and last-first==span,'Trace endpoint/span arithmetic differs')
    groups=phase_spans.summaries(events,role,clock)
    return dict(status='passed',scope='local_phase_metadata_and_source_action_correlation',**identity,
        clockSource=trace['clockSource'],eventCount=len(events),maximumEvents=trace['maximumEvents'],
        firstLocalUptimeNanoseconds=first,lastLocalUptimeNanoseconds=last,traceSpanNanoseconds=span,
        localPrimaryClock=clock,frameCount=16,committedTokens=8192,intervalGroups=groups,
        selectedDisjointIntervalTotalNanoseconds=sum(g['totalNanoseconds'] for g in groups),
        baseOutputFullyValidated=False,numericalValidationRequiredSeparately=True,runtimeProvenanceRequiredSeparately=True,
        crossProcessClockAlignmentAsserted=False,gpuOverlapAsserted=False,throughputQualified=False,
        independentNativeTimingPerformed=False,limitations=LIMITATIONS)


def check_pair(rows,traces):
    c.require(type(rows) is list and len(rows)==2 and type(traces) is list and len(traces)==2,'Two ordered ranks required')
    result=[check_records(r,t,'rank'+str(i)) for i,(r,t) in enumerate(zip(rows,traces))]
    for key in ['epoch','schedulingPolicy','recordedRequestFingerprint','requestFingerprint','agreementFingerprint',
                'promptFileSHA256','promptTokenIDsSHA256','profile','profileFingerprint']:
        c.exact(result[0][key],result[1][key],'cross-rank identity '+key)
    return dict(status='passed',scope='two_independent_local_phase_traces',ranks=result,
        crossProcessClockAlignmentAsserted=False,crossRankIntervalTotalsComputed=False,limitations=LIMITATIONS)


def validate_files(stdout_paths,trace_paths,roles):
    c.require(len(stdout_paths)==len(trace_paths)==len(roles) and len(roles) in (1,2),'Matched path/role counts required')
    paths=[Path(p) for p in list(stdout_paths)+list(trace_paths)]
    c.require(len({p.resolve() for p in paths})==len(paths),'Inputs must be distinct files')
    limits=[c.MAX_STDOUT]*len(roles)+[c.MAX_TRACE]*len(roles)
    pins=c.verify_pins();own={name:c.read(Path(__file__).parent/name,65536) for name in CORE_FILES}
    data=[c.read(p,limit) for p,limit in zip(paths,limits)]
    rows=[c.stdout_rows(raw) for raw in data[:len(roles)]];traces=[c.parse(raw) for raw in data[len(roles):]]
    if len(roles)==2:
        c.exact(list(roles),['rank0','rank1'],'rank order');result=check_pair(rows,traces)
    else:result=check_records(rows[0],traces[0],roles[0])
    c.require([c.read(p,limit) for p,limit in zip(paths,limits)]==data,'Input changed during audit')
    c.require(c.verify_pins()==pins and all(c.read(Path(__file__).parent/n,65536)==v for n,v in own.items()),
        'Source or audit helper changed during replay')
    result.update(inputs=[dict(path=str(p.resolve()),sha256=c.sha(raw),byteCount=len(raw)) for p,raw in zip(paths,data)],
        helperFiles={n:dict(sha256=c.sha(v),byteCount=len(v)) for n,v in own.items()},
        sourceExpectationPins=pins,frozenInputsUnchanged=True)
    return result


def validate_one(stdout_path,trace_path,role):return validate_files([stdout_path],[trace_path],[role])
def validate_solo(stdout_path,trace_path):return validate_one(stdout_path,trace_path,'solo')
def validate_ranks(stdout_paths,trace_paths):return validate_files(stdout_paths,trace_paths,['rank0','rank1'])


if __name__=='__main__':
    if len(sys.argv)==4 and sys.argv[1]=='solo':result=validate_solo(*sys.argv[2:])
    elif len(sys.argv)==6 and sys.argv[1]=='ranks':result=validate_ranks([sys.argv[2],sys.argv[4]],[sys.argv[3],sys.argv[5]])
    else:raise SystemExit('Usage: phase_clock_audit.py solo STDOUT TRACE | ranks STDOUT0 TRACE0 STDOUT1 TRACE1')
    print(json.dumps(result,indent=2,sort_keys=True,allow_nan=False))
