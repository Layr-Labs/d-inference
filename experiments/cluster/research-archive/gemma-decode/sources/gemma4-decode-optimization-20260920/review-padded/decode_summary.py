"""Same-process summaries of already validated reports; no input/output here."""
import policy

c=policy.base
PHASES=('graphConstruction','rootStaging','evaluation','validationCommit')


def summarize(value):
    c.exact(len(value['samples']),4,'Four decode samples including warmup')
    guard={name:dict(count=0,nanoseconds=0,nestedLogicalGuardNanoseconds=0)
           for name in c.GUARD_CATEGORIES}
    intervals={name:0 for name in ('tokenInterval','frameWallClippedToDecode','beforeOwner',
                                  'ownerSpan','afterOwner','interPhaseGaps')+PHASES}
    disjoint={name:0 for name in ('wireInclusive','wireNestedLogicalGuard','wireExcludingNestedGuard',
        'logicalGuardOutsideWire','remainderAfterWireAndOutsideGuard','betweenFrames')}
    tokens=0
    for sample in value['samples'][1:]:
        c.require(sample['warmup'] is False and sample['timingsAreSameProcess'] is True
                  and sample['clockAcrossHostsCompared'] is False,'Measured same-process intervals')
        times=sample['tokenAgreementNanoseconds'];c.exact(len(times),16,'All agreement clocks')
        elapsed=times[-1]-times[0];c.exact(elapsed,sample['decodeNanoseconds'],'Decode interval')
        frames=[f for f in sample['frames'] if f['phase']=='decode']
        c.exact(len(frames),15,'Fifteen continuation frames')
        frame_total=0
        for index,frame in enumerate(frames):
            c.exact((frame['sequence'],frame['offset'],frame['tokenCount']),(64+index,4096+index,1),'Decode frontier')
            start,end=frame['startedNanoseconds'],frame['completedNanoseconds']
            c.require(times[index]<=start<times[index+1]<=end<=times[index+1]+1_000_000,'Local frame clocks')
            phases=frame['ownerPhases']
            c.exact([p['name'] for p in phases],[p+s for p in PHASES for s in ('.begin','.end')],'Owner phase order')
            stamps=[p['timestampNanoseconds'] for p in phases]
            c.require(start<=stamps[0]<=stamps[-1]<=times[index+1]
                      and all(b>=a for a,b in zip(stamps,stamps[1:])),'Owner interval chronology')
            for i,p in enumerate(phases):
                c.exact((p['tokenCount'],p['committedTokens']),(1,4096+index+(i==7)),'Commit frontier')
            clipped=min(end,times[-1])-start;span=stamps[-1]-stamps[0]
            durations=[stamps[i+1]-stamps[i] for i in range(0,8,2)]
            for name,n in zip(PHASES,durations):intervals[name]+=n
            for name,n in dict(tokenInterval=times[index+1]-times[index],frameWallClippedToDecode=clipped,
                beforeOwner=stamps[0]-start,ownerSpan=span,afterOwner=min(end,times[-1])-stamps[-1],
                interPhaseGaps=span-sum(durations)).items():intervals[name]+=n
            frame_total+=clipped;tokens+=1
        c.exact(sample['guardMetrics']['boundary'],'request-start_to_first-token-agreement_and_first-to-last-agreement','Counter interval')
        records=sample['guardMetrics']['decode'];c.guard_counts(records)
        local={r['category']:r for r in records['records']}
        for name,row in local.items():
            for key in guard[name]:guard[name][key]+=row[key]
        wire=sum(local[n]['nanoseconds'] for n in c.GUARD_CATEGORIES[-2:])
        nested=sum(local[n]['nestedLogicalGuardNanoseconds'] for n in c.GUARD_CATEGORIES[-2:])
        logical=local['logicalGuard']['nanoseconds']
        c.require(0<=nested<=wire and nested<=logical and wire+logical-nested<=elapsed
                  and frame_total<=elapsed,'Inclusive guard/wire interval accounting')
        for name,n in dict(wireInclusive=wire,wireNestedLogicalGuard=nested,wireExcludingNestedGuard=wire-nested,
            logicalGuardOutsideWire=logical-nested,remainderAfterWireAndOutsideGuard=elapsed-wire-logical+nested,
            betweenFrames=elapsed-frame_total).items():disjoint[name]+=n
    c.exact(tokens,45,'Three measured requests by fifteen tokens')
    return dict(measuredRequests=3,excludedWarmupRequests=1,decodeTokens=tokens,
        localMillisecondsPerToken={k:v/tokens/1e6 for k,v in intervals.items()},
        guardCategories={k:dict(calls=v['count'],callsPerToken=v['count']/tokens,
            millisecondsPerToken=v['nanoseconds']/tokens/1e6,
            nestedLogicalGuardMillisecondsPerToken=v['nestedLogicalGuardNanoseconds']/tokens/1e6)
            for k,v in guard.items()},
        wireGuardMillisecondsPerToken={k:v/tokens/1e6 for k,v in disjoint.items()},
        categoriesAreInclusive=True,ownerAndWireIntervalsIncludeExistingChecks=True,
        wireExcludingGuardStillIncludesPeerWorkAndCompletion=True,pureNetworkOrGPUTimeMeasured=False)
