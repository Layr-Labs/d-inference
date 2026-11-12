"""One complete native Gemma report; numeric proof does not replace physical review."""
from contract import (ARTIFACT, CONFIGURATION, FLOATS, GLOBALS, MODES, TARGETS,
    VOCABULARY, Sidecars, bounded, fields, pinned, token_hash)
from recorded_math import canonical, digest, equal, flags, logical_bytes, parse_json, require, sha_string
from state import state


def source_load(value, binding, target, expected):
    fields(value,'artifactSHA256 configurationSHA256 planSHA256 target parameterLayoutSHA256 sourceTensorCount selectedTensorCount loadedTensorBytes largestHostTensorBytes readAccounting bf16ConversionEnabled resourceAdmissionEstablished')
    for key,wanted in dict(artifactSHA256=ARTIFACT,configurationSHA256=CONFIGURATION,
        planSHA256=expected['planSHA256'],target=target['name'],parameterLayoutSHA256=target['parameterLayoutSHA256'],
        sourceTensorCount=1697,selectedTensorCount=target['selectedTensorCount'],loadedTensorBytes=target['selectedBytes']).items():
        equal(value[key],wanted,'Exact source load '+key)
    flags(value,bf16ConversionEnabled=True,resourceAdmissionEstablished=False)
    bounded(value['largestHostTensorBytes'],1,target['selectedBytes'])
    read = value['readAccounting']
    fields(read,'schema alignmentBytes maximumScratchAllocationBytes cacheBypassRequested readAheadDisabledRequested fileCacheAbsenceEstablished selectedBytes requestedReadBytes returnedReadBytes paddingReadBytes preadCalls interruptedCalls shortEOFReads largestScratchRequestBytes largestScratchAllocationBytes')
    for key,wanted in dict(schema='checkpoint_aligned_selected_read_v1',alignmentBytes=16_384,
        maximumScratchAllocationBytes=8_404_992,selectedBytes=target['selectedBytes']).items():
        equal(read[key],wanted,'Read accounting '+key)
    flags(read,cacheBypassRequested=True,readAheadDisabledRequested=True,fileCacheAbsenceEstablished=False)
    for key in ('requestedReadBytes','returnedReadBytes','paddingReadBytes','preadCalls','interruptedCalls',
                'shortEOFReads','largestScratchRequestBytes','largestScratchAllocationBytes'):
        bounded(read[key],0,2**63-1)
    require(read['selectedBytes'] <= read['returnedReadBytes'] <= read['requestedReadBytes']
        and read['paddingReadBytes']==read['returnedReadBytes']-read['selectedBytes']
        and 1 <= read['preadCalls'] and read['interruptedCalls']<=read['preadCalls']
        and read['shortEOFReads']<=read['preadCalls']
        and 1 <= read['largestScratchRequestBytes'] <= 8_388_608
        and read['largestScratchRequestBytes']<=read['largestScratchAllocationBytes']<=8_404_992,
        'Read accounting arithmetic/bounds')
    equal(binding['readAccountingSHA256'],digest(canonical(read)),'Actual read-accounting fingerprint')


def resources(value, binding, expected, mode_index):
    fields(value,'policy planSHA256 requestSHA256 selectedTensorCount completedTensorCount constructorParameterCount constructorUnmaterializedQuantizedParameterCount constructorObservedActiveBytes constructorObservedNativePeakBytes namedNativeReserveBytes hostEvidenceReserveBytes persistentCastLogicalBytes stateLogicalBytes selectedAllocationBounds namedArrays namedAllocationBounds observationCount minimumActualFreeBytes maximumObservedActiveBytes maximumObservedNativePeakBytes actualAllocatorBoundsUsed operationalResourceChecksApplied reclaimableUsedForAdmission wholeProcessPeakBoundEstablished reserveTermsAreOperationalPolicy constructorGraphHeadroomRetainedThroughoutLoad newServingActivationFloorEstablished physicalProcessOrLeaseRetirementEstablished')
    for key,wanted in dict(policy='registered_gemma4_short_operational_resources_v1',
        planSHA256=expected['planSHA256'],requestSHA256=expected['requestSHA256'],
        selectedTensorCount=binding['selectedTensorCount'],completedTensorCount=binding['selectedTensorCount']).items():
        equal(value[key],wanted,'Resource identity/completion '+key)
    flags(value,actualAllocatorBoundsUsed=True,operationalResourceChecksApplied=True,
        reclaimableUsedForAdmission=False,wholeProcessPeakBoundEstablished=False,reserveTermsAreOperationalPolicy=True,
        constructorGraphHeadroomRetainedThroughoutLoad=True,newServingActivationFloorEstablished=False,
        physicalProcessOrLeaseRetirementEstablished=False)
    numeric = 'constructorParameterCount constructorUnmaterializedQuantizedParameterCount constructorObservedActiveBytes constructorObservedNativePeakBytes namedNativeReserveBytes hostEvidenceReserveBytes persistentCastLogicalBytes stateLogicalBytes observationCount minimumActualFreeBytes maximumObservedActiveBytes maximumObservedNativePeakBytes'.split()
    for key in numeric: bounded(value[key],0,2**63-1)
    require(value['observationCount']>0 and value['minimumActualFreeBytes']>=6*1024**3
        and value['maximumObservedNativePeakBytes']>=value['maximumObservedActiveBytes']
        and value['constructorObservedNativePeakBytes']>=value['constructorObservedActiveBytes'], 'Resource observation sanity')
    selected = value['selectedAllocationBounds']
    require(type(selected) is list and len(selected)==binding['selectedTensorCount'],'Selected allocation coverage')
    require(sum(bounded(n,1,2**63-1) for n in selected)>=binding['selectedBytes'],'Selected allocation sum')
    arrays,bounds = value['namedArrays'],value['namedAllocationBounds']
    require(type(arrays) is list and type(bounds) is list and 1<=len(arrays)<=8192
        and len(arrays)==len(bounds),'Named-array coverage/bound')
    names=set()
    for array,bound in zip(arrays,bounds):
        fields(array,'name bytes')
        require(type(array['name']) is str and 0<len(array['name'])<=512 and array['name'] not in names,'Named-array identity')
        names.add(array['name'])
        require(bounded(bound,1,2**63-1)>=bounded(array['bytes'],1,2**63-1),'Named allocator bound')
    equal(sum(bounds),value['namedNativeReserveBytes'],'Named native reserve arithmetic')
    equal(sum(a['bytes'] for a in arrays if a['name'].startswith('constantCast:')),
        value['persistentCastLogicalBytes'],'Persistent cast ledger sum')
    state_bytes = sum(2*(34 if g%6==5 else 1024)*(2*512 if g%6==5 else 8*256)*4 for g in GLOBALS[mode_index])
    host_bytes = sum(2*34*(2*512 if g%6==5 else 8*256)*4 for g in GLOBALS[mode_index])
    host_bytes += 2*VOCABULARY*4 + 2*16*2816*4 + 1_048_576
    equal(value['stateLogicalBytes'],state_bytes,'Operational F32 state ceiling')
    equal(value['hostEvidenceReserveBytes'],host_bytes,'Named host-evidence reserve')


def report(reference, expected, prompt, mode_index):
    fields(reference,'report sidecarsDirectory')
    record = pinned(reference['report'],1_048_577)  # Native 1 MiB JSON plus its stdout LF.
    value = parse_json(record['raw'])
    fields(value,'schema mode expected execution resources modelReleased nativeExecuted collectiveCreated physicalProcessOrLeaseRetirementEstablished runtimeServingEnabled numericalComparisonPerformed throughputMeasurementValid encryptedRDMAEstablished collectiveReleased nativeCacheBytesAfterRelease')
    equal(value['schema'],'gemma4_short_result_v1','Native report schema')
    equal(value['mode'],MODES[mode_index],'Native report role')
    equal(value['expected'],expected,'Report matches prospective expected description')
    flags(value,modelReleased=True,nativeExecuted=True,collectiveCreated=mode_index!=0,
        physicalProcessOrLeaseRetirementEstablished=False,runtimeServingEnabled=False,numericalComparisonPerformed=False,
        throughputMeasurementValid=False,encryptedRDMAEstablished=False,collectiveReleased=mode_index!=0)
    equal(value['nativeCacheBytesAfterRelease'],0,'Freed-buffer cache after release')
    execution = value['execution']
    fields(execution,'binding sourceLoad selectedTokenIDs selectedTokenIDsSHA256 frames rows finalState files finishReason committedTokens requestStateRetired modelReleaseNotYetEstablished mtpEnabled throughputMeasurementValid numericalComparisonPerformed')
    flags(execution,requestStateRetired=True,modelReleaseNotYetEstablished=True,mtpEnabled=False,
        throughputMeasurementValid=False,numericalComparisonPerformed=False)
    equal(execution['finishReason'],'length','Request finish reason')
    equal(execution['committedTokens'],33,'Consumed input frontier')
    tokens=execution['selectedTokenIDs']
    require(type(tokens) is list and len(tokens)==2,'Exactly two selected output tokens')
    equal(token_hash(tokens),execution['selectedTokenIDsSHA256'],'Selected token hash')
    target=expected['targets'][mode_index]
    binding=execution['binding']
    fields(binding,'target planSHA256 artifactSHA256 configurationSHA256 parameterLayoutSHA256 stateLayoutSHA256 readAccountingSHA256 selectedTensorCount selectedBytes maximumTokens maximumChunkTokens layers probePrefillTokens probeDecodeTokens')
    for key,wanted in dict(target=TARGETS[mode_index],planSHA256=expected['planSHA256'],artifactSHA256=ARTIFACT,
        configurationSHA256=CONFIGURATION,parameterLayoutSHA256=target['parameterLayoutSHA256'],
        selectedTensorCount=target['selectedTensorCount'],selectedBytes=target['selectedBytes'],maximumTokens=34,
        maximumChunkTokens=16,probePrefillTokens=2,probeDecodeTokens=1).items():
        equal(binding[key],wanted,'Actual session binding '+key)
    sha_string(binding['stateLayoutSHA256']);sha_string(binding['readAccountingSHA256'])
    source_load(execution['sourceLoad'],binding,target,expected)
    resources(value['resources'],binding,expected,mode_index)
    frames=execution['frames']
    require(type(frames) is list and len(frames)==3,'Three exact forward frames')
    for sequence,frame_tokens in enumerate((prompt[:16],prompt[16:],[tokens[0]])):
        frame=frames[sequence]
        fields(frame,'sequence frontier tokenIDsSHA256'+(' boundarySHA256' if mode_index else ''))
        equal([frame['sequence'],frame['frontier'],frame['tokenIDsSHA256']],
            [sequence,(16,32,33)[sequence],token_hash(frame_tokens)],'Frame sequence/input binding')
        if mode_index: sha_string(frame['boundarySHA256'])
    sidecars=Sidecars(reference['sidecarsDirectory'],execution['files'])
    rows=execution['rows']
    require(type(rows) is list and len(rows)==(0 if mode_index==1 else 2),'Full row coverage')
    row_bytes,files=[],[]
    for ordinal,row in enumerate(rows):
        fields(row,'ordinal frontier tokenID maximumTieCount file dtype logicalBytesSHA256')
        require(row['dtype'] in FLOATS,'Unknown native row dtype')
        equal([row['ordinal'],row['frontier'],row['tokenID']],[ordinal,32+ordinal,tokens[ordinal]],'Row token/frontier')
        fields(row['file'],'name bytes sha256')
        equal(row['file']['name'],f'row-{ordinal}.json','Row sidecar name')
        full_row=parse_json(sidecars.read(row['file']))
        logical=logical_bytes(full_row,VOCABULARY,row['dtype'])
        equal(full_row['logicalBytesSHA256'],sha_string(row['logicalBytesSHA256']),'Row logical identity')
        maximum=max(full_row['values']); first=full_row['values'].index(maximum)
        equal(first,row['tokenID'],'Native argmax first maximum')
        equal(full_row['values'].count(maximum),row['maximumTieCount'],'Native maximum tie count')
        row_bytes.append(dict(dtype=row['dtype'],raw=logical,sha256=digest(logical)))
        files.append(row['file'])
    states,state_files=state(execution['finalState'],binding,sidecars,mode_index)
    equal(execution['files'],files+state_files,'Exact native sidecar publication order')
    file_receipts=sidecars.finish()
    return dict(tokens=tokens,frames=frames,rows=row_bytes,state=states,layers=binding['layers'],
        receipt=dict(reportSHA256=record['sha256'],reportBytes=record['size_bytes'],files=file_receipts,
            sourceReadAccountingSHA256=binding['readAccountingSHA256'],stateFingerprint=execution['finalState']['fingerprint']))
