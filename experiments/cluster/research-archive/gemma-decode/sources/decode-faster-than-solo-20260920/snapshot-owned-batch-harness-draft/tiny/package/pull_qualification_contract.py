"""Exact tiny-fixture observations only; no model or performance acceptance."""
from binding_common import require
GROUPS=['seven-roots-queued-fenced-pull-finish','queued-work-cancelled-after-fence',
 'post-receive-check-failure-retains-roots','stale-sequence-refused','nonzero-padding-refused']
def validate_result(v,job,local,wrapper):
    require(job['promptCount']==128 and local['captureEvidence'] is False,'Closed qualifier metadata')
    require(v['schema']=='gemma4_remote_mtp_owned_batch_qualification_v1' and v['configuration']==wrapper
        and v['role']==wrapper['role'] and v['rank']==(1 if wrapper['role']=='target' else 0),'Qualifier role/config')
    require(v['groups']==GROUPS and v['groupCount']==5 and v['snapshotFrontiers']==[3,1031,3]
        and v['completedSnapshotTransfers']==21 and v['receiverRetainedRootLimit']==9
        and v['queuedAcknowledgements']==2 and v['completedPulls']==1 and v['cancelledUnpulledProposals']==2,'Actual fixture membership/counts')
    for key in ['passed','staleSequenceRefused','nonzeroPaddingRefused','poisonedChannelReuseRefused','injectedPostReceiveCheckFailure',
        'nativeExecuted','jacclExecuted','allFixtureRootsRetired','collectiveCreated','collectiveReleased']:
        require(v[key] is True,'Missing completed fixture fact: '+key)
    for key in ['actualGPUFaultInjected','gemmaWeightsExecuted','assistantWeightsExecuted','targetForwardExecuted','realAssistantProposalExecuted',
        'throughputMeasured','numericalComparisonPerformed','servingEnabled','encryptedRDMAEstablished','originalProcessRetirementEstablished','wholeProcessPeakBoundEstablished']:
        require(v[key] is False,'Unestablished qualifier claim: '+key)
    require(v['nativeReserveBytes']==128*1024**2 and v['hostReserveBytes']==2*1024**2
        and v['minimumActualFreeBytes']>=10*1024**3+130*1024**2 and 0<=v['peakExtraActiveBytes']<=128*1024**2
        and v['resourceObservations']>0 and v['nativeCacheBytesAfterRelease']==0
        and v['guardObservationPolicy']=='gemma4_invocation_fresh_observation_v1'
        and v['guardMetrics']['schema']=='gemma4_guard_wall_counters_v1','Fixture resource/guard observations')
    require(v.get('snapshotTransferPolicy')=='gemma4_owned_snapshot_batch_gpu_boundaries_v1' and v.get('injectedPreassemblyCheckFailure') is True
        and v.get('noncontiguousFullHeadProducers') is True
        and v.get('hiddenDTypesQualified')==['bfloat16','float16','float32'], 'Actual owned batch path/type/failure qualification')
    require(type(v.get('perSnapshotTransferCount')) is int and v['perSnapshotTransferCount']==7
        and type(v.get('perSnapshotCheckedBoundaryCount')) is int and v['perSnapshotCheckedBoundaryCount']==2,
        'Exact batch boundary/transfer counts')
    return v
