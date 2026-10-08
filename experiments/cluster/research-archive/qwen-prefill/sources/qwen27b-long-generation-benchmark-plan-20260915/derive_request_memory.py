"""Independent metadata-only replay of the existing named 27B 8K request bounds."""
from pathlib import Path
import hashlib
import json

ROOT=Path('/Users/developer/DarkbloomDev/cluster-research')
BASE=Path(__file__).resolve().parent
CONSTRUCTOR=ROOT/'qwen27b-expected-generation-identity-20260915/inputs/constructor.stdout.jsonl'
PAGE=16384
GIB=1024**3


def bound(n):
    normalized=((n+PAGE-1)//PAGE)*PAGE if n>PAGE else n
    return normalized+min(normalized-1,2*PAGE-1)


def derive(tensors):
    assert len(tensors)==1847 and sum(x['byteCount'] for x in tensors.values())==15132802048
    conv=4*3*(2*16*128+48*128)
    ssm=4*48*128*128
    kv=2*4*8320*4*256
    boundary=512*5120*4
    logical=3*48*(conv+ssm)+16*(kv+4)+max(conv,ssm,kv//2)+2*boundary
    assert logical==1616248896
    parts=[('convolution',conv,144),('ssm',ssm,144),('key_or_value_capacity',kv//2,32),
           ('attention_offset',4,16),('largest_host_snapshot',max(conv,ssm,kv//2),1),('boundary',boundary,2)]
    state=sum(bound(n)*count for _,n,count in parts)
    ranks=[]
    for rank,lo,hi in ((0,0,16),(1,16,64)):
        fusion=[]
        for layer in range(lo,hi):
            if (layer+1)%4==0:continue
            for suffix in ('weight','scales','biases'):
                names=['language_model.model.layers.'+str(layer)+'.linear_attn.'+p+'.'+suffix
                       for p in ('in_proj_qkv','in_proj_z','in_proj_b','in_proj_a')]
                leaves=[tensors[name] for name in names]
                assert all(x['shape'][1]==leaves[0]['shape'][1] for x in leaves)
                n=sum(t['byteCount'] for t in leaves)
                fusion.append(dict(layer=layer,suffix=suffix,logicalBytes=n,allocationBoundBytes=bound(n)))
        f=sum(a['allocationBoundBytes'] for a in fusion);base=state+f
        row=248320*2 if rank else 0;floating=248320*4 if rank else 0
        captureNative=bound(row)+bound(floating) if rank else 0;captureHost=row+floating
        extraN=bound(512*5120*2) if rank==0 else 0;extraH=(512*5120*2 if rank==0 else 0)+65536
        ranks.append(dict(rank=rank,layers=hi-lo,recurrentLayers=(hi-lo)*3//4,stateAllocationBoundBytes=state,
            fusionLogicalBytes=sum(a['logicalBytes'] for a in fusion),fusionAllocationBoundBytes=f,
            baseRequestReservedBytes=base,recordingExtraNativeBytes=captureNative,recordingExtraHostBytes=captureHost,
            serialRecordingReservedBytes=base+captureNative+captureHost,
            serialRequiredActualFreeBytes=max(6*GIB,base+captureNative+captureHost+4*GIB),
            serialAllocatorAdditionalBytes=base+captureNative+2*GIB,
            lookaheadExtraNativeBytes=extraN,lookaheadExtraHostBytes=extraH,
            lookaheadRequiredActualFreeBytes=max(6*GIB,base+captureNative+captureHost+extraN+extraH+4*GIB),
            lookaheadAllocatorAdditionalBytes=base+captureNative+extraN+2*GIB,fusionLeaves=fusion))
    allalloc=sum(bound(t['byteCount']) for t in tensors.values());host=max(t['byteCount'] for t in tensors.values())
    capNative=bound(248320*2)+bound(248320*4);capHost=2*248320*(2+4)
    fusion=sum(a['fusionAllocationBoundBytes'] for a in ranks);fullrequest=state+fusion+capNative+capHost
    return dict(logicalNamedStateBytes=logical,stateBoundComponents=[dict(name=name,logicalBytes=n,count=count,
        perArrayBound=bound(n)) for name,n,count in parts],ranks=ranks,
        fullReference=dict(requestReservedBytes=fullrequest,sourceAllocationBoundBytes=allalloc,
            initialRequiredActualFreeBytes=allalloc+2*host+(8*1024**2+PAGE)+fullrequest+4*GIB,
            postloadRequiredActualFreeBytes=max(6*GIB,fullrequest+4*GIB),
            initialAllocatorAdditionalBytes=allalloc+host+state+fusion+capNative+2*GIB))


def main():
    raw=CONSTRUCTOR.read_bytes()
    assert hashlib.sha256(raw).hexdigest()=='563414858fcec6228884c13b9b1aa8669d1c22097bd10b848a60f820aca51794'
    value=json.loads(raw);tensors={x['sourceName']:x for s in value['stages'] for x in s['expectedActiveTensors']}
    result=derive(tensors);prior=json.loads((BASE/'request-memory.json').read_bytes())
    for key,value in result.items():assert prior[key]==value,key
    print(json.dumps(dict(passed=True,exactReplayOfRetainedCalculation=True,sourceTensorCount=len(tensors),
        constructorSHA256=hashlib.sha256(raw).hexdigest(),allocatorPageBytes=PAGE,
        compilerModelOrRemoteExecuted=False),sort_keys=True))


if __name__=='__main__':main()
