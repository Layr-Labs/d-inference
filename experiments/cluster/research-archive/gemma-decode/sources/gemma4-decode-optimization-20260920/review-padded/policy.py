"""Explicit padded-framing deltas over the frozen timestamp contract."""
import sys
from pathlib import Path

ROOT=Path(__file__).resolve().parent.parent
sys.path.insert(0,str(ROOT/'review'))
import compare_three_roles as base
exact,require=base.exact,base.require


def geometry():
    # Four requests, including warmup; 64 prefill and 15 decode frames each.
    # Every request has begin/ready/request-retired checkpoints (two controls
    # each). Two initial probe frames have three controls each. Model release
    # is one final bilateral checkpoint. No lifecycle messages are omitted.
    f,d,r,p=64,15,4,2
    scopes={
        'prefill':dict(send=f+1,receive=2*f+1,payload=f),
        'decode':dict(send=2*d,receive=3*d,payload=d),
        'global':dict(send=r*(f+1+2*d+3)+p+1,
                      receive=r*(2*f+1+3*d+3)+2*p+1,payload=r*(f+d)+p),
    }
    require(scopes['global']['send']+scopes['global']['receive']==1108,'Global control derivation')
    return scopes


def expected_counts(old,rank,scope):
    require(rank is None or type(rank) is int and rank in (0,1),'Exact stage rank')
    result=dict(old)
    if rank is None:return result
    row=geometry()[scope];send,receive=row['send'],row['receive']
    if rank==1:send,receive=receive,send
    payload=row['payload'];controls=send+receive;logical=8*controls
    expected_old_wire=dict(wireSendCompleted=2*send+(payload if rank==0 else 0),
                           wireReceiveCompleted=2*receive+(payload if rank==1 else 0))
    for name,count in expected_old_wire.items():exact(old[name],count,'Baseline exact '+scope+' '+name)
    factors={'logicalGuard':1,'entryGuard':2,'ownerGuard':1,'environmentGuard':3,
             'osSnapshot':1,'nativeSnapshot':1,'outerNativeFault':8}
    for name,factor in factors.items():
        result[name]-=factor*logical
        require(result[name]>=0,'Guard delta exceeds recorded baseline')
    result['wireSendCompleted']-=send;result['wireReceiveCompleted']-=receive
    return result


def cadence(new,old,rank):
    if rank is None:return base.same_cadence(new,old)
    exact(len(new['samples']),4,'Complete new cohort')
    exact(len(old['samples']),4,'Complete baseline cohort')
    exact(new['guardObservationPolicy'],old['guardObservationPolicy'],'fresh guard policy unchanged')
    exact(new['guardObservationPolicy'],'gemma4_invocation_fresh_observation_v1','fresh scope')
    global_counts=base.guard_counts(new['guardMetrics'])
    exact(global_counts,expected_counts(base.guard_counts(old['guardMetrics']),rank,'global'),'Global explicit framing delta')
    requests=[]
    for a,b in zip(new['samples'],old['samples']):
        exact(a['ordinal'],b['ordinal'],'Same request ordinal')
        exact(a['warmup'],b['warmup'],'Same warmup exclusion')
        exact(a['guardMetrics']['boundary'],b['guardMetrics']['boundary'],'same interval boundary')
        counts={}
        for phase in ('prefill','decode'):
            counts[phase]=base.guard_counts(a['guardMetrics'][phase])
            exact(counts[phase],expected_counts(base.guard_counts(b['guardMetrics'][phase]),rank,phase),
                  f'ordinal{a["ordinal"]} exact {phase} delta')
        exact(counts['decode']['wireSendCompleted'],45,'Three decode sends/token')
        exact(counts['decode']['wireReceiveCompleted'],45,'Three decode receives/token')
        exact(counts['decode']['logicalGuard'],15*(65 if rank==0 else 63),'Decode guard cadence')
        exact(len(a['frames']),len(b['frames']),'same frame count')
        for x,y in zip(a['frames'],b['frames']):
            exact({k:x[k] for k in ('sequence','phase','offset','tokenCount')},
                  {k:y[k] for k in ('sequence','phase','offset','tokenCount')},'same frame cadence')
            exact([{k:v for k,v in z.items() if k!='timestampNanoseconds'} for z in x['ownerPhases']],
                  [{k:v for k,v in z.items() if k!='timestampNanoseconds'} for z in y['ownerPhases']],
                  'same state commit/owner phase cadence')
        requests.append(dict(ordinal=a['ordinal'],warmup=a['warmup'],counts=counts))
    return dict(globalCounts=global_counts,requests=requests,removedPrefixes=geometry(),
                removedGlobalLogicalGuardCalls=8864,removedGlobalSendPrefixes=395 if rank==0 else 713,
                removedGlobalReceivePrefixes=713 if rank==0 else 395)


def budget(new,old,rank):
    if rank is None:return base.same_budget(new,old)
    require(type(rank) is int and rank in (0,1),'Exact stage rank')
    a,b=new['resources'],old['resources']
    exact(set(a),set(b),'same resource schema')
    changed={'namedArrays','namedAllocationBounds','namedNativeReserveBytes','hostEvidenceReserveBytes','observationCount'}
    exact({k:v for k,v in a.items() if k not in base.RESOURCE_VARIABLES|changed},
          {k:v for k,v in b.items() if k not in base.RESOURCE_VARIABLES|changed},'All non-control budget fields unchanged')
    indexes=[i for i,x in enumerate(a['namedArrays']) if x['name']=='paddedControlFrame']
    require(len(indexes)==1 and all(x['name']!='paddedControlFrame' for x in b['namedArrays']), 'One new padded allocation')
    i=indexes[0];exact(a['namedArrays'][i],dict(name='paddedControlFrame',bytes=16384),'Padded logical shape')
    bound=a['namedAllocationBounds'][i]
    require(type(bound) is int and bound>=16384,'Actual rounded native control bound')
    exact(a['namedArrays'][:i]+a['namedArrays'][i+1:],b['namedArrays'],'Original named terms unchanged')
    exact(a['namedAllocationBounds'][:i]+a['namedAllocationBounds'][i+1:],b['namedAllocationBounds'],
          'Original actual allocation bounds unchanged')
    exact(a['namedNativeReserveBytes'],b['namedNativeReserveBytes']+bound,'Additive native charge')
    exact(a['hostEvidenceReserveBytes'],b['hostEvidenceReserveBytes']+32768,'Additive host charge')
    exact(a['observationCount'],b['observationCount']-8864,'Only derived prefix checks removed')
    if rank==0:require(i==len(a['namedArrays'])-2 and a['namedArrays'][-1]['name']=='lookaheadPreparedBoundary',
                       'Prepared boundary stays last and independently charged')
    else:exact(i,len(a['namedArrays'])-1,'Receiver control term is appended')
    for value in (a,b):
        require(value['actualAllocatorBoundsUsed'] is True and value['operationalResourceChecksApplied'] is True
                and value['reclaimableUsedForAdmission'] is False and value['minimumActualFreeBytes']>=6*1024**3
                and value['completedTensorCount']==value['selectedTensorCount']
                and type(value['observationCount']) is int and value['observationCount']>0,'Unchanged actual resource gates')
        require(len(value['namedArrays'])==len(value['namedAllocationBounds']) and
                all(type(n) is int and n>=x['bytes']>0 for x,n in zip(value['namedArrays'],value['namedAllocationBounds']))
                and value['namedNativeReserveBytes']==sum(value['namedAllocationBounds']),'All native sums')
    exact(a['requestSHA256'],new['samples'][0]['requestSHA256'],'Actual new resource identity')
    exact(b['requestSHA256'],old['samples'][0]['requestSHA256'],'Actual old resource identity')
    return dict(extraLogicalNativeBytes=16384,actualExtraNativeBound=bound,extraHostBytes=32768,
                nativeBefore=b['namedNativeReserveBytes'],nativeAfter=a['namedNativeReserveBytes'],
                hostBefore=b['hostEvidenceReserveBytes'],hostAfter=a['hostEvidenceReserveBytes'],
                resourceObservationCountBefore=b['observationCount'],resourceObservationCountAfter=a['observationCount'],
                unchangedLookaheadAllowance=a['prefillAllowance'])
