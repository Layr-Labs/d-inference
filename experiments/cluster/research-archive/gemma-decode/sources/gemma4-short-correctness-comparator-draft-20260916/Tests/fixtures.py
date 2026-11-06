"""Fabricated file evidence for CPU-only parser tests; never physical qualification."""
import copy
import hashlib
import json
from pathlib import Path
import struct
import sys
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from contract import ARTIFACT, CONFIGURATION, GLOBALS, MANIFEST, MODES, SELECTED_COUNTS, TARGETS


def raw_json(value):
    return json.dumps(value,sort_keys=True,separators=(',',':'),allow_nan=False).encode()


def sha(raw):return hashlib.sha256(raw).hexdigest()
def lines(values,sep='\n'):return sha(sep.join(map(str,values)).encode())
def tokens(values):return sha(','.join(map(str,values)).encode())


def write(path,raw):
    path.write_bytes(raw)
    return dict(path=str(path),sha256=sha(raw))


def describe(prompt_raw):
    profile=dict(identifier='registered_gemma4_26b_forward_validation_v1',vocabularySize=262144,
        hiddenSize=2816,activationDType='bfloat16',maximumPromptTokens=8192,maximumChunkTokens=512,
        maximumOutputTokens=128,maximumContextTokens=8320)
    profile['fingerprint']=lines(['qwen-stage-generation-profile-v1']+list(profile.values()),'|')
    request='00112233-4455-6677-8899-aabbccddeeff'; epoch='ffeeddcc-bbaa-9988-7766-554433221100'
    prompt=json.loads(prompt_raw)
    request_hash=lines(['qwen-stage-generation-request-v1',profile['fingerprint'],request,
        'prompt='+tokens(prompt),'chunk=16','output=2','stop='])
    build='b'*64;plan='c'*64
    value=dict(schema='gemma4_short_expected_v1',membershipEpoch=epoch,buildIdentitySHA256=build,
        requestID=request,requestSHA256=request_hash,promptFileSHA256=sha(prompt_raw),promptTokenIDsSHA256=tokens(prompt),
        profile=profile,planSHA256=plan,stageSHA256=['d'*64,'e'*64],mappingSHA256='f'*64,
        artifactSHA256=ARTIFACT,configurationSHA256=CONFIGURATION,manifestSHA256=MANIFEST,
        cut=10,promptCount=32,chunkSize=16,outputCount=2,maximumTokens=34,finalFrontier=33,stopTokenIDs=[],
        metadataOnly=True,actualPayloadLoaded=False,actualKVTypeObserved=False,
        buildIdentityRequiresParentVerification=True,runtimeExecutionAuthorized=False)
    value['scopeSHA256']=lines(['gemma4-short-correctness-v1',epoch,build,plan,request_hash,sha(prompt_raw),
        'exact-bytes-before-any-numerical-qualification','mtp=false','cut=10'])
    # Selected byte totals are explicit fabricated metadata under the pinned
    # description. These tests do not replay an actual artifact constructor.
    value['targets']=[dict(name=name,parameterLayoutSHA256=sha(name.encode()),selectedTensorCount=SELECTED_COUNTS[i],
        selectedBytes=14_467_688_508 if i==0 else (4_000_000_000 if i==1 else 10_500_000_000),
        globalLayerIndices=GLOBALS[i]) for i,name in enumerate(TARGETS)]
    return value


def refresh_state(report):
    execution=report['execution'];state=execution['finalState']
    identities=[]
    for e in state['entries']:
        identity=f"{e['globalLayerIndex']}|{e['component']}|{e['shape']}|{e['dtype']}|{e['byteCount']}|{e['sha256']}"
        if e['logicalRange']:identity+=f"|range={e['logicalRange'][0]}:{e['logicalRange'][1]}"
        identities.append(identity)
    state['fingerprint']=lines(['cbv2-owned-attention-state-v2',execution['binding']['stateLayoutSHA256'],'tokens=33']+identities)


def make_report(directory,expected,index):
    target=expected['targets'][index]
    layers=[]
    for local,g in enumerate(GLOBALS[index]):
        full=g%6==5
        layers.append(dict(localIndex=local,globalIndex=g,kvHeads=2 if full else 8,headDimension=512 if full else 256,
            window=0 if full else 1024,dtype='float32' if full else 'bfloat16'))
    layout=lines(['attention-state-layout-v1','maximumTokens=34','maximumChunkTokens=16','prefix=false','speculation=false']+
        [f"{v['localIndex']}|{v['globalIndex']}|{v['kvHeads']}|{v['headDimension']}|{'full' if v['window']==0 else v['window']}|{v['dtype']}" for v in layers])
    count=target['selectedTensorCount'];size=target['selectedBytes']
    read=dict(schema='checkpoint_aligned_selected_read_v1',alignmentBytes=16384,maximumScratchAllocationBytes=8404992,
        cacheBypassRequested=True,readAheadDisabledRequested=True,fileCacheAbsenceEstablished=False,
        selectedBytes=size,requestedReadBytes=size,returnedReadBytes=size,paddingReadBytes=0,preadCalls=count,
        interruptedCalls=0,shortEOFReads=0,largestScratchRequestBytes=8388608,largestScratchAllocationBytes=8404992)
    binding=dict(target=target['name'],planSHA256=expected['planSHA256'],artifactSHA256=ARTIFACT,configurationSHA256=CONFIGURATION,
        parameterLayoutSHA256=target['parameterLayoutSHA256'],stateLayoutSHA256=layout,readAccountingSHA256=sha(raw_json(read)),
        selectedTensorCount=count,selectedBytes=size,maximumTokens=34,maximumChunkTokens=16,layers=layers,probePrefillTokens=2,probeDecodeTokens=1)
    load=dict(artifactSHA256=ARTIFACT,configurationSHA256=CONFIGURATION,planSHA256=expected['planSHA256'],target=target['name'],
        parameterLayoutSHA256=target['parameterLayoutSHA256'],sourceTensorCount=1697,selectedTensorCount=count,
        loadedTensorBytes=size,largestHostTensorBytes=1024,readAccounting=read,bf16ConversionEnabled=True,resourceAdmissionEstablished=False)
    files=[]
    def sidecar(name,raw):
        (directory/name).write_bytes(raw)
        value=dict(name=name,bytes=len(raw),sha256=sha(raw));files.append(value);return value
    selected=[7,9];rows=[]
    if index!=1:
        for ordinal,token in enumerate(selected):
            values=[0]*262144;values[token]=1
            raw=bytearray(262144*2);raw[token*2:token*2+2]=b'\x80\x3f'
            logit=dict(shape=[1,262144],dtype='bfloat16',byteCount=len(raw),logicalBytesSHA256=sha(raw),values=values)
            rows.append(dict(ordinal=ordinal,frontier=32+ordinal,tokenID=token,maximumTieCount=1,
                file=sidecar(f'row-{ordinal}.json',raw_json(logit)),dtype='bfloat16',logicalBytesSHA256=sha(raw)))
    entries=[]
    for layer in layers:
        g=layer['globalIndex']
        for component in ('kv.keys','kv.position_offsets','kv.values'):
            position=component=='kv.position_offsets'
            dtype='int32' if position else layer['dtype']
            shape=[1] if position else [1,layer['kvHeads'],33,layer['headDimension']]
            size=4 if position else 33*layer['kvHeads']*layer['headDimension']*(4 if dtype=='float32' else 2)
            raw=struct.pack('<i',33) if position else bytes(size)
            entries.append(dict(localLayerIndex=layer['localIndex'],globalLayerIndex=g,component=component,dtype=dtype,
                sha256=sha(raw),shape=shape,byteCount=size,logicalRange=[] if position else [0,33],
                file=sidecar(f'state-{g}-{component}.bin',raw)))
    frames=[]
    for sequence,ids in enumerate((list(range(16)),list(range(16,32)),[selected[0]])):
        f=dict(sequence=sequence,frontier=(16,32,33)[sequence],tokenIDsSHA256=tokens(ids))
        if index:f['boundarySHA256']=sha(str(sequence).encode())
        frames.append(f)
    execution=dict(binding=binding,sourceLoad=load,selectedTokenIDs=selected,selectedTokenIDsSHA256=tokens(selected),
        frames=frames,rows=rows,finalState=dict(frontier=33,fingerprint='0'*64,entries=entries),files=files,
        finishReason='length',committedTokens=33,requestStateRetired=True,modelReleaseNotYetEstablished=True,
        mtpEnabled=False,throughputMeasurementValid=False,numericalComparisonPerformed=False)
    state_bytes=sum(2*(34 if g%6==5 else 1024)*(2*512 if g%6==5 else 8*256)*4 for g in GLOBALS[index])
    host=sum(2*34*(2*512 if g%6==5 else 8*256)*4 for g in GLOBALS[index])+2*262144*4+2*16*2816*4+1048576
    resources=dict(policy='registered_gemma4_short_operational_resources_v1',planSHA256=expected['planSHA256'],requestSHA256=expected['requestSHA256'],
        selectedTensorCount=count,completedTensorCount=count,constructorParameterCount=count,constructorUnmaterializedQuantizedParameterCount=1,
        constructorObservedActiveBytes=0,constructorObservedNativePeakBytes=0,namedNativeReserveBytes=1,
        hostEvidenceReserveBytes=host,persistentCastLogicalBytes=0,stateLogicalBytes=state_bytes,
        selectedAllocationBounds=[(target['selectedBytes']+count-1)//count]*count,namedArrays=[dict(name='fabricated-term',bytes=1)],
        namedAllocationBounds=[1],observationCount=1,minimumActualFreeBytes=6*1024**3,maximumObservedActiveBytes=0,
        maximumObservedNativePeakBytes=0,actualAllocatorBoundsUsed=True,operationalResourceChecksApplied=True,
        reclaimableUsedForAdmission=False,wholeProcessPeakBoundEstablished=False,reserveTermsAreOperationalPolicy=True,
        constructorGraphHeadroomRetainedThroughoutLoad=True,newServingActivationFloorEstablished=False,
        physicalProcessOrLeaseRetirementEstablished=False)
    result=dict(schema='gemma4_short_result_v1',mode=MODES[index],expected=copy.deepcopy(expected),execution=execution,resources=resources,
        modelReleased=True,nativeExecuted=True,collectiveCreated=index!=0,physicalProcessOrLeaseRetirementEstablished=False,
        runtimeServingEnabled=False,numericalComparisonPerformed=False,throughputMeasurementValid=False,
        encryptedRDMAEstablished=False,collectiveReleased=index!=0,nativeCacheBytesAfterRelease=0)
    refresh_state(result)
    return result


def bundle(root):
    prompt=raw_json(list(range(32)));expected=describe(prompt)
    packet=dict(schema='gemma4_short_comparison_packet_v1',expected=write(root/'expected.json',raw_json(expected)),
        prompt=write(root/'prompt.json',prompt),results={})
    for index,mode in enumerate(MODES):
        directory=root/mode;directory.mkdir()
        value=make_report(directory,expected,index)
        packet['results'][mode]=dict(report=write(root/(mode+'.json'),raw_json(value)),sidecarsDirectory=str(directory))
    return packet


def mutate_report(packet,mode,action):
    path=Path(packet['results'][mode]['report']['path']);value=json.loads(path.read_bytes())
    action(value)
    packet['results'][mode]['report']=write(path,raw_json(value))


def replace_sidecar(packet,mode,name,raw):
    path=Path(packet['results'][mode]['sidecarsDirectory'])/name;path.write_bytes(raw)
    def edit(report):
        e=report['execution']
        replacement=dict(name=name,bytes=len(raw),sha256=sha(raw))
        for file in e['files']:
            if file['name']==name:file.update(replacement)
        for row in e['rows']:
            if row['file']['name']==name:
                row['file']=replacement.copy();row['logicalBytesSHA256']=json.loads(raw)['logicalBytesSHA256']
        for entry in e['finalState']['entries']:
            if entry['file']['name']==name:
                entry['file']=replacement.copy();entry['sha256']=sha(raw)
        refresh_state(report)
    mutate_report(packet,mode,edit)
