"""Supplementary CPU audit of selected owner markers within coarse local phases.

No candidate numerical buffers or model payloads are read. Numerical and
runtime/source provenance audits are required separately for each new run.
"""
from pathlib import Path
import json
import sys
import owner_dependencies as d

MAX_OWNER_BYTES=65536
CORE_FILES=['owner_clock_audit.py','owner_dependencies.py']
PHASES=['graphConstruction.begin','graphConstruction.end','rootStaging.begin','rootStaging.end',
 'evaluation.begin','evaluation.end','validationCommit.begin','validationCommit.end']
PARENTS={'solo':('prefill.begin','prefill.committed'),'rank0':('prepare.begin','prepare.committed'),
 'rank1':('receive.beginConsumption','receive.consumptionAndSelectionValidated')}
TRACE_FIELDS='kind schemaVersion identity clockSource maximumEvents events firstLocalUptimeNanoseconds lastLocalUptimeNanoseconds traceSpanNanoseconds diagnosticOnly includesRecorderOverhead evaluationIntervalIncludesExistingErrorCheck crossProcessClockAlignmentAsserted gpuKernelTimeAsserted gpuOverlapAsserted modelReleaseAsserted recorderIndependentlyVerifiesOuterSuccess'
LIMITATIONS=[
 'This is supplementary CPU metadata validation. The separately frozen numerical oracle must qualify the same stdout, and runtime/source/archive provenance must bind actual executable, native invocation and sidecars. Model tensors, payloads, final states/logits, selection and memory are not independently validated here.',
 'Clock provenance and callback placement are source-bound assertions, not independently measured execution. A coherently fabricated JSON stream cannot be disproved by metadata replay. The fixed identity correlates the full recorded history, but this helper does not separately bind it to an original raw prompt file.',
 'Owner and parent clocks are compared only within the same reported request role. There is no cross-rank clock alignment, cross-process critical path, GPU overlap, operator GPU duration, measured observer overhead or causal speedup claim.',
 'The evaluation interval includes the existing post-eval native/deadline check. Graph construction can include existing initialization work, root staging is CPU ownership work, and validation/commit includes existing checks/readbacks. No additional synchronization is assumed.',
 'The four owner intervals are disjoint but gaps between markers remain unclassified. Time outside them in the enclosing parent interval also remains unclassified; neither difference measures overhead or communication.',
 'All eight callbacks can precede a later failure. Successful stdout flags and trace availability do not independently prove retirement/publication ordering; the outer owner must have succeeded and provenance must verify that gate.'
]


def check_records(rows,phase_trace,owner_trace,role):
    phase,c=d.phase()
    coarse=phase.check_records(rows,phase_trace,role)
    c.fields(owner_trace,TRACE_FIELDS,'selected owner trace')
    c.flags(owner_trace,kind='qwen_prefill_selected_owner_trace',schemaVersion=1,clockSource='DispatchTime.uptimeNanoseconds',
        maximumEvents=8,diagnosticOnly=True,includesRecorderOverhead=True,evaluationIntervalIncludesExistingErrorCheck=True,
        crossProcessClockAlignmentAsserted=False,gpuKernelTimeAsserted=False,gpuOverlapAsserted=False,
        modelReleaseAsserted=False,recorderIndependentlyVerifiesOuterSuccess=False)
    identity=dict(requestFingerprint=coarse['recordedRequestFingerprint'],profile=c.PROFILE,role=role,
        frameSequence=7,tokenOffset=3584,tokenCount=512,committedFrontier=4096)
    c.exact(owner_trace['identity'],identity,'selected owner identity')
    events=owner_trace['events'];c.require(type(events) is list and len(events)==8,'Exactly eight owner events required')
    prior=0
    for index,(event,name) in enumerate(zip(events,PHASES)):
        c.fields(event,'ordinal phase tokenCount committedTokens localUptimeNanoseconds','owner event')
        wanted=dict(ordinal=index,phase=name,tokenCount=512,committedTokens=4096 if index==7 else 3584)
        for key,value in wanted.items():c.exact(event[key],value,'owner event '+key)
        now=c.integer(event['localUptimeNanoseconds']);c.require(now>=prior,'Owner local clock reversed');prior=now
    first=c.integer(owner_trace['firstLocalUptimeNanoseconds']);last=c.integer(owner_trace['lastLocalUptimeNanoseconds'])
    span=c.integer(owner_trace['traceSpanNanoseconds'])
    c.require(first==events[0]['localUptimeNanoseconds'] and last==events[7]['localUptimeNanoseconds']
        and first<=last and last-first==span,'Owner endpoints/span differ')
    start_name,end_name=PARENTS[role]
    def parent_marker(name):
        values=[x for x in phase_trace['events'] if x['phase']==name and x.get('frameSequence')==7]
        c.require(len(values)==1,'Unique selected parent marker required');return values[0]
    start=parent_marker(start_name);end=parent_marker(end_name)
    c.require(start['ordinal']<end['ordinal'] and start['committedTokens']==3584 and end['committedTokens']==4096,
        'Parent selected frame frontier/order differs')
    low=start['localUptimeNanoseconds'];high=end['localUptimeNanoseconds']
    c.require(low<=first<=last<=high,'Selected owner timestamps leave the same-role parent interval')
    # Each timestamp lies within these endpoints because all eight are nondecreasing.
    intervals=[]
    for i,name in enumerate(['graphConstruction','rootStaging','evaluationAndExistingErrorCheck','validationCommit']):
        left=events[2*i];right=events[2*i+1]
        intervals.append(dict(name=name,startOrdinal=left['ordinal'],endOrdinal=right['ordinal'],
            startPhase=left['phase'],endPhase=right['phase'],
            elapsedNanoseconds=right['localUptimeNanoseconds']-left['localUptimeNanoseconds']))
    total=sum(x['elapsedNanoseconds'] for x in intervals)
    c.require(0<=total<=span<=high-low,'Disjoint owner totals exceed enclosing span')
    result=dict(status='passed',scope='selected_chunk7_local_owner_phase_correlation',role=role,identity=identity,
        profileFingerprint=coarse['profileFingerprint'],requestFingerprint=coarse['requestFingerprint'],
        recordedRequestFingerprint=coarse['recordedRequestFingerprint'],promptFileSHA256=coarse['promptFileSHA256'],
        promptTokenIDsSHA256=coarse['promptTokenIDsSHA256'],ownerClockSource=owner_trace['clockSource'],
        coarsePhaseEventCount=coarse['eventCount'],ownerEventCount=8,firstLocalUptimeNanoseconds=first,
        lastLocalUptimeNanoseconds=last,traceSpanNanoseconds=span,
        parent=dict(startPhase=start_name,endPhase=end_name,startOrdinal=start['ordinal'],endOrdinal=end['ordinal'],
            firstLocalUptimeNanoseconds=low,lastLocalUptimeNanoseconds=high,elapsedNanoseconds=high-low),
        intervals=intervals,selectedDisjointIntervalTotalNanoseconds=total,
        unclassifiedGapsWithinOwnerTraceNanoseconds=span-total,
        unclassifiedParentTimeOutsideOwnerIntervalsNanoseconds=high-low-total,
        allOwnerEventsContainedInSameRoleSelectedParent=True,coarsePhaseMetadataValidated=True,
        baseOutputFullyValidated=False,numericalValidationRequiredSeparately=True,runtimeProvenanceRequiredSeparately=True,
        crossProcessClockAlignmentAsserted=False,gpuKernelTimeAsserted=False,gpuOverlapAsserted=False,
        overheadIndependentlyMeasured=False,throughputQualified=False,limitations=LIMITATIONS)
    for key in ['epoch','schedulingPolicy','agreementFingerprint']:
        if key in coarse:result[key]=coarse[key]
    return result


def check_pair(rows,phase_traces,owner_traces):
    phase,c=d.phase()
    c.require(type(rows) is list and type(phase_traces) is list and type(owner_traces) is list
        and len(rows)==len(phase_traces)==len(owner_traces)==2,'Two ordered input triples required')
    result=[check_records(rows[i],phase_traces[i],owner_traces[i],'rank'+str(i)) for i in range(2)]
    for key in ['epoch','schedulingPolicy','agreementFingerprint','recordedRequestFingerprint','requestFingerprint',
                'profileFingerprint','promptFileSHA256','promptTokenIDsSHA256']:
        c.exact(result[0][key],result[1][key],'pair identity '+key)
    return dict(status='passed',scope='two_independent_selected_owner_local_intervals',ranks=result,
        crossRankIntervalTotalsComputed=False,crossProcessClockAlignmentAsserted=False,
        gpuKernelTimeAsserted=False,overheadIndependentlyMeasured=False,limitations=LIMITATIONS)


def validate_files(stdout_paths,phase_paths,owner_paths,roles):
    _,c=d.phase();count=len(roles)
    c.require(count in (1,2) and len(stdout_paths)==len(phase_paths)==len(owner_paths)==count,'Matched input counts required')
    paths=[Path(x) for x in list(stdout_paths)+list(phase_paths)+list(owner_paths)]
    c.require(len({x.resolve() for x in paths})==len(paths),'Input paths must be distinct')
    limits=[c.MAX_STDOUT]*count+[c.MAX_TRACE]*count+[MAX_OWNER_BYTES]*count
    pins=d.verify_pins();phase_pins=c.verify_pins()
    own={name:c.read(Path(__file__).parent/name,65536) for name in CORE_FILES}
    raw=[c.read(p,limit) for p,limit in zip(paths,limits)]
    rows=[c.stdout_rows(x) for x in raw[:count]]
    full=[c.parse(x) for x in raw[count:2*count]];selected=[c.parse(x) for x in raw[2*count:]]
    if count==1:result=check_records(rows[0],full[0],selected[0],roles[0])
    else:
        c.exact(list(roles),['rank0','rank1'],'rank input order');result=check_pair(rows,full,selected)
    c.require([c.read(p,limit) for p,limit in zip(paths,limits)]==raw,'Audit inputs changed during replay')
    c.require(d.verify_pins()==pins and c.verify_pins()==phase_pins
        and all(c.read(Path(__file__).parent/n,65536)==b for n,b in own.items()),'Helper/source dependency changed during replay')
    result.update(inputs=[dict(path=str(p.resolve()),sha256=c.sha(b),byteCount=len(b)) for p,b in zip(paths,raw)],
        helperFiles={n:dict(sha256=c.sha(b),byteCount=len(b)) for n,b in own.items()},
        sourceExpectationPins=pins,coarsePhaseSourceExpectationPins=phase_pins,frozenInputsUnchanged=True)
    return result


def validate_one(stdout_path,phase_path,owner_path,role):return validate_files([stdout_path],[phase_path],[owner_path],[role])
def validate_solo(stdout_path,phase_path,owner_path):return validate_one(stdout_path,phase_path,owner_path,'solo')
def validate_ranks(stdout_paths,phase_paths,owner_paths):return validate_files(stdout_paths,phase_paths,owner_paths,['rank0','rank1'])


if __name__=='__main__':
    if len(sys.argv)==5 and sys.argv[1]=='solo':result=validate_solo(*sys.argv[2:])
    elif len(sys.argv)==8 and sys.argv[1]=='ranks':
        result=validate_ranks([sys.argv[2],sys.argv[5]],[sys.argv[3],sys.argv[6]],[sys.argv[4],sys.argv[7]])
    else:raise SystemExit('Usage: owner_clock_audit.py solo STDOUT PHASE OWNER | ranks STDOUT0 PHASE0 OWNER0 STDOUT1 PHASE1 OWNER1')
    print(json.dumps(result,indent=2,sort_keys=True,allow_nan=False))
