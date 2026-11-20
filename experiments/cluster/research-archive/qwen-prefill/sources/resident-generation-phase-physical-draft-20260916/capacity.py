"""Prospective exact named-array arithmetic; actual Ready/ACKs must match it."""
PAGE=16384

def native_bound(n):
    # Exact pinned Metal AllocationFootprintPolicy{page,page,0,0,page}.
    assert type(n) is int and n>0
    rounded=(n+PAGE-1)//PAGE*PAGE if n>PAGE else n
    return rounded+min(rounded-1,2*PAGE-1)

def derive(host, policy):
    assert policy in ('serial','oneChunkLookahead')
    assert host['maximumEvents']==288 and host['encodedResultAllocationBytes']>=256*1024
    assert host['requiredHostReservationBytes']==sum(host[k] for k in (
        'eventAllocationBytes','encodedResultAllocationBytes','encodingScratchAllowanceBytes','metadataAllowanceBytes'))
    # QwenLongPrefillTensorBudget + QwenResidentRequestAllowance, full-model
    # F32 state on each rank; exact 27B geometry, no per-stage relaxation.
    conv=4*3*(2*16*128+48*128)
    ssm=4*48*128*128
    kv_half=4*8320*4*256
    boundary=512*5120*4
    logical=3*48*(conv+ssm)+16*(2*kv_half+4)+max(conv,ssm,kv_half)+2*boundary
    assert logical==1616248896
    state=sum([144*native_bound(conv),144*native_bound(ssm),32*native_bound(kv_half),
        16*native_bound(4),native_bound(max(conv,ssm,kv_half)),2*native_bound(boundary)])
    # Exact 576 pinned source leaves: qkv/z/b/a rows [10240,6144,48,48],
    # uint32 packed weight width640; BF16 scale/bias width80. Fused once per GDN.
    fused_rows=10240+6144+48+48
    fused=[fused_rows*640*4,fused_rows*80*2,fused_rows*80*2]
    rows=[]
    for rank,count in enumerate([12,36]):
        fusion=count*sum(native_bound(n) for n in fused)
        extra_native=native_bound(512*5120*2) if policy=='oneChunkLookahead' and rank==0 else 0
        extra_host=(512*5120*2 if rank==0 else 0)+65536 if policy=='oneChunkLookahead' else 0
        total=state+fusion+extra_native+extra_host+host['requiredHostReservationBytes']
        rows.append(dict(rank=rank,stateBytes=state,fusionBytes=fusion,baseReservedBytes=state+fusion,
            prefillExtraNativeBytes=extra_native,prefillExtraHostBytes=extra_host,
            phaseHostBytes=host['requiredHostReservationBytes'],totalReservedBytes=total,
            requiredRequestActualFreeBytes=max(6*1024**3,total+4*1024**3)))
    return dict(schema='resident_phase_prospective_capacity_v1',policy=policy,pageSize=PAGE,
        hostBudget=host,ranks=rows,pairCapacityBytes=sum(x['totalReservedBytes'] for x in rows),
        actualNativeAdmissionEstablished=False,wholeProcessPeakBoundProved=False)
