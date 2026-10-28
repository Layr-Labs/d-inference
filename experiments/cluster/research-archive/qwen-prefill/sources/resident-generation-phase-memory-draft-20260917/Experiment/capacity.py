"""Prospective named-array arithmetic only; retain C512 Ready and C256 request separately."""
PAGE=16384

def native_bound(n):
    if type(n) is not int or n<=0:raise ValueError('Positive native bytes required')
    rounded=(n+PAGE-1)//PAGE*PAGE if n>PAGE else n
    return rounded+min(rounded-1,2*PAGE-1)

def state(chunk):
    conv=4*3*(2*16*128+48*128);ssm=4*48*128*128;kv_half=4*8320*4*256
    boundary=chunk*5120*4
    return sum([144*native_bound(conv),144*native_bound(ssm),32*native_bound(kv_half),
        16*native_bound(4),native_bound(max(conv,ssm,kv_half)),2*native_bound(boundary)])

def derive(host,policy):
    fields={'maximumEvents','eventLogicalBytes','eventAllocationBytes','memoryLogicalBytes','memoryAllocationBytes',
        'encodedResultAllocationBytes','encodingScratchAllowanceBytes','metadataAllowanceBytes','requiredHostReservationBytes'}
    if type(host) is not dict or set(host)!=fields or any(type(v) is not int or v<=0 for v in host.values()):
        raise ValueError('Exact actual Foundation host-budget metadata required')
    if policy not in ('serial','oneChunkLookahead') or host['maximumEvents']!=544:
        raise ValueError('Closed C256 phase scope required')
    if host['eventAllocationBytes']<host['eventLogicalBytes'] or host['memoryAllocationBytes']<host['memoryLogicalBytes'] or host['encodedResultAllocationBytes']<1024**2 or host['encodingScratchAllowanceBytes']<2*1024**2 or host['metadataAllowanceBytes']<16384:
        raise ValueError('Named host allocations undercharged')
    if host['requiredHostReservationBytes']!=sum(host[k] for k in ['eventAllocationBytes','memoryAllocationBytes',
        'encodedResultAllocationBytes','encodingScratchAllowanceBytes','metadataAllowanceBytes']) or host['requiredHostReservationBytes']>8*1024**2:
        raise ValueError('Host allocation sum/bound differs')
    fused_rows=10240+6144+48+48
    fused=[fused_rows*640*4,fused_rows*80*2,fused_rows*80*2]
    rows=[]
    for rank,count in enumerate([12,36]):
        fusion=count*sum(native_bound(n) for n in fused)
        native=native_bound(256*5120*2) if policy=='oneChunkLookahead' and rank==0 else 0
        retained=(256*5120*2 if rank==0 else 0)+65536 if policy=='oneChunkLookahead' else 0
        extra=native+retained+host['requiredHostReservationBytes']
        ready=state(512)+fusion+extra
        request=state(256)+fusion+extra
        rows.append(dict(rank=rank,readyMaximumChunkTokens=512,requestChunkTokens=256,
            readyStateBytes=state(512),requestStateBytes=state(256),fusionBytes=fusion,
            prefillExtraNativeBytes=native,prefillExtraHostBytes=retained,phaseHostBytes=host['requiredHostReservationBytes'],
            readyCapacityBytes=ready,requestReservationBytes=request,
            loadedGuardRequiredActualFreeBytes=max(6*1024**3,state(512)+fusion+host['requiredHostReservationBytes']+4*1024**3),
            requestRequiredActualFreeBytes=max(6*1024**3,request+4*1024**3)))
    return dict(schema='resident_phase_memory_prospective_capacity_v1',policy=policy,pageSize=PAGE,
        configurationPrefillSchedule='serial_v1',hostBudget=host,ranks=rows,
        actualNativeAdmissionEstablished=False,wholeProcessPeakBoundProved=False)
