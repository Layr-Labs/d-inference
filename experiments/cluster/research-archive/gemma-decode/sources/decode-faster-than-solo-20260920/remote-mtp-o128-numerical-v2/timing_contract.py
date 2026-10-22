"""Same-target clock and counter joins; these are not pure-network timings."""
from binding_common import require

PHASES=('proposalFillNanoseconds','lookaheadGrantNanoseconds','targetNanoseconds','selectionNanoseconds',
    'proposalDrainNanoseconds','reconcileNanoseconds','resolutionACKNanoseconds','branchRetirementNanoseconds',
    'conditioningReseedNanoseconds','finishNanoseconds')
TARGET=('targetPrepareNanoseconds','targetAdmissionNanoseconds','targetExecutionNanoseconds')
COUNTS=('sends','receives','completedOperations','entryResourceChecks','exitResourceChecks','innerLifetimeChecks')
FLAGS=dict(sameTargetProcessWallClock=True,assistantGPUTimeMeasured=False,overlappingPhaseTotalsAreAdditive=False,
    requestControlExcludesCohortBarriers=True,targetSubphasesIncludedInTargetTotal=True,windowTotalsIncludeUnclassifiedBookkeeping=True)

def uint(value):return type(value) is int and 0<=value<2**64

def request_timing(sample,output_count,depth):
    value=sample['phaseTiming']
    require(type(value) is dict and set(value)==set(FLAGS)|{'schema','maximumRecords','windows','finalFinishNanoseconds','controlDelta'},'Exact request timing fields')
    require(value['schema']=='gemma4_remote_mtp_target_window_timings_v1'
        and type(value['maximumRecords']) is int and value['maximumRecords']==128,'Timing schema/capacity')
    for key,want in FLAGS.items():require(value[key] is want,'Timing clock/overlap semantics: '+key)
    rows=value['windows'];widths=sample['verificationWidths'];accepted=sample['acceptedPrefixes']
    require(type(rows) is list and 1<=len(rows)==len(widths)==len(accepted)<=output_count-1<=127,'Timing coverage bound')
    total=0
    for ordinal,row in enumerate(rows):
        require(type(row) is dict and set(row)==set(PHASES)|set(TARGET)|{'ordinal','kind','width','accepted','totalNanoseconds'},'Exact window timing fields')
        require(type(row['ordinal']) is int and row['ordinal']==ordinal
            and type(row['width']) is int and row['width']==widths[ordinal] and 1<=row['width']<=depth+1
            and type(row['accepted']) is int and row['accepted']==accepted[ordinal] and 0<=row['accepted']<row['width'],'Timing/window prefix join')
        kind=row['kind']
        require((ordinal==0 and kind=='prime' and row['width']==1 and row['accepted']==0)
            or (ordinal>0 and kind=='verification' and row['width']>=2)
            or (ordinal==len(rows)-1 and ordinal>0 and kind=='tail' and row['width']==1 and row['accepted']==0),'Timing kind/order')
        for key in (*PHASES,*TARGET,'totalNanoseconds'):require(uint(row[key]),'Bounded monotonic duration: '+key)
        require(row['totalNanoseconds']>0 and sum(row[key] for key in PHASES)<=row['totalNanoseconds']
            and sum(row[key] for key in TARGET)<=row['targetNanoseconds'],'Disjoint wall totals or nested target totals differ')
        if kind!='verification':
            require(all(row[key]==0 for key in ('proposalFillNanoseconds','lookaheadGrantNanoseconds','proposalDrainNanoseconds',
                'resolutionACKNanoseconds','branchRetirementNanoseconds')),'Prime/tail has verification-only phase')
        if kind!='tail':require(row['finishNanoseconds']==0,'Finish belongs only to tail or final request finish')
        if kind=='tail':require(row['conditioningReseedNanoseconds']==0,'Tail cannot reseed')
        total+=row['totalNanoseconds']
    require(uint(value['finalFinishNanoseconds']) and uint(sample['decodeNanoseconds'])
        and total+value['finalFinishNanoseconds']<=sample['decodeNanoseconds'],'Window clocks exceed decode wall interval')
    if rows[-1]['kind']=='tail':require(value['finalFinishNanoseconds']==0,'Tail already completed finish')
    delta=value['controlDelta']
    require(type(delta) is dict and set(delta)==set(COUNTS) and all(uint(delta[k]) for k in COUNTS),'Exact request control delta')
    require(delta['sends']==delta['receives']>0 and delta['completedOperations']==delta['sends']+delta['receives']
        and delta['entryResourceChecks']==delta['exitResourceChecks']==delta['completedOperations']
        and delta['innerLifetimeChecks']>=delta['completedOperations'],'Request control chronology')
    return delta

def validate_cohort_timing(value,job,local):
    require(len(value['samples'])==4,'Four timed requests')
    deltas=[request_timing(sample,job['outputCount'],local['maximumDraftTokens']) for sample in value['samples']]
    metrics=value['controlResourceMetrics']
    # loaded + four request-retired + models-released: one send/receive each.
    for key,cohort in [('sends',6),('receives',6),('completedOperations',12),('entryResourceChecks',12),('exitResourceChecks',12)]:
        require(sum(d[key] for d in deltas)+cohort==metrics[key],'Request/cohort counter join: '+key)
    require(sum(d['innerLifetimeChecks'] for d in deltas)+12<=metrics['innerLifetimeChecks'],'Cohort lifetime checks omitted')
