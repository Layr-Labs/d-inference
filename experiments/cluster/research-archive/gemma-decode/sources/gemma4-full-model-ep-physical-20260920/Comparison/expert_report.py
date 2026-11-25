"""Full replicated-state EP reports; uses unchanged native-row/state readers."""
import uuid
from contract import (ARTIFACT,CONFIGURATION,GLOBALS,VOCABULARY,FLOATS,Sidecars,bounded,
    expected_description,fields,pinned,token_hash,text_hash)
from recorded_math import canonical,digest,equal,flags,logical_bytes,parse_json,require,sha_string
from report import source_load,resources
from state import state

MODES=('full','expert0','expert1')

def expected(value,prompt_raw):
    fields(value,'schema scopeSHA256 original globalExpertIDsByRank ownershipSHA256 rankBuildSHA256 targets assignmentLimit payloadByteLimit sharedQualificationMaximumAssignments replicatedFullStatePerRank metadataOnly runtimeExecutionAuthorized expertNumericalQualificationEstablished')
    equal(value['schema'],'gemma4_full_expert_expected_v1','EP expected schema')
    prompt=expected_description(value['original'],prompt_raw)
    ids=value['globalExpertIDsByRank']
    require(type(ids) is list and len(ids)==2 and all(type(row) is list and 0<len(row)<128 for row in ids),'Two expert banks')
    require(all(all(type(i) is int for i in row) and row==sorted(set(row)) for row in ids)
            and sorted(ids[0]+ids[1])==list(range(128)),'Complete disjoint global IDs')
    equal(value['ownershipSHA256'],digest(canonical(ids)),'Ownership identity')
    builds=value['rankBuildSHA256'];require(type(builds) is list and len(builds)==2,'Two build pins')
    for build in builds:sha_string(build)
    original=value['original']
    equal(value['scopeSHA256'],text_hash(['gemma4-full-expert-correctness-v1',original['membershipEpoch'],
        original['requestSHA256'],original['planSHA256'],original['promptFileSHA256'],ARTIFACT,CONFIGURATION,
        value['ownershipSHA256']]+builds,'|'),'Actual common EP scope')
    equal([value['assignmentLimit'],value['payloadByteLimit'],value['sharedQualificationMaximumAssignments']],
        [128,128*2816*2,1024],'Fixed full-model envelope')
    flags(value,replicatedFullStatePerRank=True,metadataOnly=True,runtimeExecutionAuthorized=False,
        expertNumericalQualificationEstablished=False)
    require(type(value['targets']) is list and len(value['targets'])==3,'Three prospective targets')
    for index,target in enumerate(value['targets']):
        fields(target,'name parameterLayoutSHA256 selectedTensorCount selectedBytes globalLayerIndices')
        equal(target['name'],MODES[index],'Target order')
        equal(target['globalLayerIndices'],list(range(30)),'Replicated complete decoder')
        equal(target['selectedTensorCount'],1339,'Complete selected text tensor inventory')
        equal(target['selectedBytes'],14_467_688_508 if index==0 else 1_621_321_788+len(ids[index-1])*30*3_345_408,'Selected axis0 bytes')
        sha_string(target['parameterLayoutSHA256'])
    return prompt

def expert_resources(receipt,binding,description,index):
    ordinary=dict(receipt)
    if index:
        extra=ordinary.pop('expertResources');rank=index-1
        fields(extra,'policy ownershipSHA256 rank ownedExpertCount frameTokenLimit assignmentLimit payloadByteLimit hostBytes arrayTerms collectiveNativeAllowanceBytes collectiveHostAllowanceBytes measuredPeakBoundEstablished')
        arrays=[];a=128
        def add(name,size):arrays.append(dict(name=name,bytes=size))
        for layer in range(30):
            prefix=f'layer{layer}:ep:'
            for name in ('paddedInput','sortedInput','paddedDown','paddedUnsort'):add(prefix+name,a*2816*4)
            for name in ('paddedGate','paddedUp','paddedActivation'):add(prefix+name,a*704*4)
            for name in ('tokenRows','localIDs','order','inverseOrder','sortedIDs','reassemblyOrder'):add(prefix+name,a*4)
            for name in ('senderGather','senderOwned','peerOwned','rankMajorJoin','slotReassembly'):add(prefix+name,a*2816*4)
            add(prefix+'senderCopyIndex',a*4)
        for name in ('controlSend','controlReceive','controlSendPrefix','controlReceivePrefix'):
            add('ep:'+name,4 if name.endswith('Prefix') else 4096)
        add('ep:collectiveNativeAllowance',32*1024**2)
        host=32*1024**2+a*(5*48+6*8+3*4)+16*2816*2+16*8*2+3*a*2816*2+8*4096+150*4096+8*1024**2
        equal(extra,dict(policy='gemma4_full_expert_correctness_resources_v1',ownershipSHA256=description['ownershipSHA256'],
            rank=rank,ownedExpertCount=len(description['globalExpertIDsByRank'][rank]),frameTokenLimit=16,
            assignmentLimit=a,payloadByteLimit=a*2816*2,hostBytes=host,arrayTerms=arrays,
            collectiveNativeAllowanceBytes=32*1024**2,collectiveHostAllowanceBytes=32*1024**2,
            measuredPeakBoundEstablished=False),'Exact additive EP ledger')
        equal([row for row in ordinary['namedArrays'] if ':ep:' in row['name'] or row['name'].startswith('ep:')],arrays,'EP arrays charged in owner')
        ordinary['hostEvidenceReserveBytes']-=host
    else:require('expertResources' not in ordinary,'Ordinary reference has EP ledger')
    # Validate common full-decoder state/casts/bounds and the original host terms.
    # No report role/state is relabelled: each actual binding owns globals0..<30.
    resources(ordinary,binding,description['original'],0)

def exchange_records(value,description,index):
    records=value['exchangeObservations']
    equal(len(records),150 if index else 0,'Complete actual exchange transcript')
    equal([value['controlRecordsSent'],value['controlRecordsReceived']],[607,607] if index else [0,0],'Complete control retirement')
    if not index:
        equal([value['sentTensorBytes'],value['receivedTensorBytes']],[0,0],'Ordinary has no transport');return
    original=description['original'];sent=received=0;cursor=0
    for purpose,positions in [('probe',[(0,'prefill',0,2,True),(1,'decode',2,1,False)]),
                              ('request',[(0,'prefill',0,16,False),(1,'prefill',16,16,True),(2,'decode',32,1,False)])]:
        for sequence,phase,offset,count,final in positions:
            for layer in range(30):
                record=records[cursor];cursor+=1
                fields(record,'scope scopeSHA256 rank0OutputSHA256 rank1OutputSHA256')
                scope=record['scope'];fields(scope,'binding frame globalLayer tokenCount dtype routeSHA256 inputSHA256 weightsSHA256 assignmentCounts projectionPolicies')
                binding=scope['binding'];fields(binding,'purpose requestID membershipEpoch requestSHA256 artifactSHA256 configurationSHA256 rankBuildSHA256 ownershipSHA256')
                for key in ('requestID','membershipEpoch'):
                    equal(str(uuid.UUID(binding[key])),original[key],'Exchange UUID join')
                wanted=dict(purpose=purpose,requestID=binding['requestID'],membershipEpoch=binding['membershipEpoch'],
                    requestSHA256=original['requestSHA256'],artifactSHA256=ARTIFACT,configurationSHA256=CONFIGURATION,
                    rankBuildSHA256=description['rankBuildSHA256'],ownershipSHA256=description['ownershipSHA256'])
                equal(binding,wanted,'Exchange admitted identity')
                equal(scope['frame'],dict(sequence=sequence,phase=phase,tokenOffset=offset,tokenCount=count,finalPromptChunk=final),'Exact frame')
                equal([scope['globalLayer'],scope['tokenCount'],scope['dtype']],[layer,count,'bfloat16'],'Layer geometry')
                for key in ('routeSHA256','inputSHA256','weightsSHA256'):sha_string(scope[key])
                counts=scope['assignmentCounts'];require(type(counts) is list and len(counts)==2,'Rank assignment counts')
                for c in counts:bounded(c,0,count*8)
                equal(sum(counts),count*8,'Global top-k assignment count')
                equal(scope['projectionPolicies'],[dict(globalAssignments=count*8,globalExperts=128,
                    ownedExperts=len(description['globalExpertIDsByRank'][r]),localAssignments=counts[r],
                    sortAssignments=count*8>=64,sortedProjection=False,executedAssignments=counts[r]) for r in range(2)],'Same full-bank kernel geometry; padding excluded')
                equal(record['scopeSHA256'],digest(canonical(scope)),'Actual scope hash')
                for r in range(2):
                    h=sha_string(record[f'rank{r}OutputSHA256'])
                    if counts[r]==0:equal(h,digest(b''),'Empty-rank digest')
                sent+=counts[index-1]*2816*2;received+=counts[2-index]*2816*2
    equal([value['sentTensorBytes'],value['receivedTensorBytes']],[sent,received],'Actual unpadded tensor byte totals')

def report(value,description,prompt,sidecar_directory,index):
    fields(value,'schema mode expected execution resources modelReleased exchangeObservations sentTensorBytes receivedTensorBytes controlRecordsSent controlRecordsReceived nativeExecuted collectiveCreated physicalProcessOrLeaseRetirementEstablished runtimeServingEnabled numericalComparisonPerformed throughputMeasurementValid encryptedRDMAEstablished collectiveReleased nativeCacheBytesAfterRelease')
    equal([value['schema'],value['mode']],['gemma4_full_expert_result_v1',MODES[index]],'Actual report mode')
    equal(value['expected'],description,'Actual result/prospective expected join')
    flags(value,modelReleased=True,nativeExecuted=True,collectiveCreated=index!=0,collectiveReleased=index!=0,
        physicalProcessOrLeaseRetirementEstablished=False,runtimeServingEnabled=False,numericalComparisonPerformed=False,
        throughputMeasurementValid=False,encryptedRDMAEstablished=False)
    equal(value['nativeCacheBytesAfterRelease'],0,'Actual cache retired')
    e=value['execution'];fields(e,'binding sourceLoad selectedTokenIDs selectedTokenIDsSHA256 frames rows finalState files finishReason committedTokens requestStateRetired modelReleaseNotYetEstablished mtpEnabled throughputMeasurementValid numericalComparisonPerformed')
    flags(e,requestStateRetired=True,modelReleaseNotYetEstablished=True,mtpEnabled=False,throughputMeasurementValid=False,numericalComparisonPerformed=False)
    equal([e['finishReason'],e['committedTokens']],['length',33],'Actual request retirement')
    tokens=e['selectedTokenIDs'];require(type(tokens) is list and len(tokens)==2,'Two generated IDs')
    equal(token_hash(tokens),e['selectedTokenIDsSHA256'],'Generated IDs hash')
    target=dict(description['targets'][index]);name='full-reference'
    if index:
        text=f'gemma4_expert_axis0_v1|128|8|30|{index-1}|'+ '|'.join(','.join(map(str,row)) for row in description['globalExpertIDsByRank'])
        name=f'expert-rank-{index-1}:'+digest(text.encode())
    target['name']=name;b=e['binding'];original=description['original']
    fields(b,'target planSHA256 artifactSHA256 configurationSHA256 parameterLayoutSHA256 stateLayoutSHA256 readAccountingSHA256 selectedTensorCount selectedBytes maximumTokens maximumChunkTokens layers probePrefillTokens probeDecodeTokens')
    for key,wanted in dict(target=name,planSHA256=original['planSHA256'],artifactSHA256=ARTIFACT,
        configurationSHA256=CONFIGURATION,parameterLayoutSHA256=target['parameterLayoutSHA256'],selectedTensorCount=1339,
        selectedBytes=target['selectedBytes'],maximumTokens=34,maximumChunkTokens=16,probePrefillTokens=2,probeDecodeTokens=1).items():equal(b[key],wanted,'Actual binding '+key)
    source_load(e['sourceLoad'],b,target,original);expert_resources(value['resources'],b,description,index)
    equal(e['frames'],[dict(sequence=i,frontier=(16,32,33)[i],tokenIDsSHA256=token_hash(t))
        for i,t in enumerate((prompt[:16],prompt[16:],[tokens[0]]))],'Committed frame inputs')
    sidecars=Sidecars(str(sidecar_directory),e['files']);rows=[];files=[]
    require(type(e['rows']) is list and len(e['rows'])==2,'Both complete vocabulary rows')
    for ordinal,row in enumerate(e['rows']):
        fields(row,'ordinal frontier tokenID maximumTieCount file dtype logicalBytesSHA256')
        equal([row['ordinal'],row['frontier'],row['tokenID']],[ordinal,32+ordinal,tokens[ordinal]],'Actual row identity')
        require(row['dtype'] in FLOATS,'Native row type');fields(row['file'],'name bytes sha256')
        equal(row['file']['name'],f'row-{ordinal}.json','Row sidecar name')
        data=parse_json(sidecars.read(row['file']));raw=logical_bytes(data,VOCABULARY,row['dtype'])
        equal(row['logicalBytesSHA256'],digest(raw),'Row byte join')
        maximum=max(data['values']);equal(data['values'].index(maximum),tokens[ordinal],'Complete row argmax')
        equal(row['maximumTieCount'],sum(v==maximum for v in data['values']),'Complete argmax tie count')
        rows.append(dict(dtype=row['dtype'],raw=raw));files.append(row['file'])
    states,state_files=state(e['finalState'],b,sidecars,0);files+=state_files
    equal(e['files'],files,'Exact full92 sidecar closure');sidecars.finish()
    exchange_records(value,description,index)
    return dict(tokens=tokens,rows=rows,state=states,layers=b['layers'],exchanges=value['exchangeObservations'])
