#!/usr/bin/env python3
"""Small retained-header arithmetic, not a native allocation or launch permit."""
import hashlib,json,math,re
from pathlib import Path
ROOT=Path('/Users/developer/DarkbloomDev/cluster-research')
INVENTORY=ROOT/'gemma4-26b-distributed-artifact-20260915/tensor-inventory.json'
CONFIG=ROOT/'gemma4-26b-distributed-artifact-20260915/metadata/config.json'
BUDGET=ROOT/'gemma4-resident-benchmark-20260920/proposed/libs/darkbloom-cluster/Sources/DarkbloomClusterRuntime/Gemma4BenchmarkResourceBudget.swift'
raw=json.loads(INVENTORY.read_text())['tensors']
t=json.loads(CONFIG.read_text())['text_config']
H=t['hidden_size'];V=t['vocab_size'];Q=t['num_attention_heads'];GIB=1<<30

def project(prompt,cut,target,capture=True,chunk=128):
    assert target in ('full','stage0','stage1')
    globals=list(range(30)) if target=='full' else list(range(cut)) if target=='stage0' else list(range(cut,30))
    head=target!='stage0'; selected={}
    for name,value in raw.items():
        if not name.startswith('language_model.model.'):continue
        layer=re.match(r'language_model.model.layers.(\d+)\.',name)
        if layer:
            if int(layer[1]) in globals:selected[name]=value
        elif name.startswith('language_model.model.embed_tokens.') or (name=='language_model.model.norm.weight' and head):
            selected[name]=value
    native=0;state=0;snapshot=0
    def add(shape,count=1,bytes=4):
        nonlocal native
        native+=math.prod(shape)*bytes*count
    for name,value in selected.items():
        if name.endswith(('.scales','.biases')) and value['dtype'] in ('BF16','F16'):
            if name.startswith('language_model.model.embed_tokens.') and not head:continue
            add(value['shape'])
    n=prompt+16;m=chunk
    for layer in globals:
        full=t['layer_types'][layer]=='full_attention'
        heads=t['num_global_key_value_heads'] if full else t['num_key_value_heads']
        dim=t['global_head_dim'] if full else t['head_dim']
        slots=n if full else t['sliding_window']
        add([slots,heads,dim],2)
        state+=2*slots*heads*dim*4;snapshot+=2*min(n,slots)*heads*dim*4
        if not full:
            add([slots,heads,dim],2);add([slots-1+m,heads,dim],2)
        add([1],3)
        add([m,H],16);add([m,Q,dim],5);add([m,heads,dim],4)
        add([n,heads,dim],2);add([Q,m,n],2);add([m,n],bytes=1)
        add([m,2112],4);add([H]);add([m,128],2);add([m,8],5);add([m*8],4)
        add([m*8,H],4);add([m*8,704],3)
        add([3,heads,dim],2)
    if target in ('full','stage0'):
        add([m]);add([m,H//2],bytes=1);add([m,H//64],2);add([m,H])
    add([m,H],3)
    if head:add([V],4)
    selectedBytes=sum(v['data_offsets'][1]-v['data_offsets'][0] for v in selected.values())
    largest=max(v['data_offsets'][1]-v['data_offsets'][0] for v in selected.values())
    evidence=(snapshot if capture else 0)+(8*V*4 if capture else 0)+2*m*H*4+8_388_608
    free=max(6*GIB,selectedBytes+2*largest+(8*1048576+16384)+native+evidence+4*GIB)
    return dict(prompt=prompt,cut=cut,target=target,capture=capture,chunk=chunk,selectedTensorCount=len(selected),selectedBytes=selectedBytes,namedNativeLogicalBytes=native,hostEvidenceBytes=evidence,stateLogicalBytes=state,minimumFreeBeforeLoadLogicalLowerBound=free)

anchors=[]
for cut,name in [(10,'describe.stdout'),(8,'cut8-description.json')]:
    path=ROOT/'gemma4-execution-20260920/metadata-checks'/name
    observed=json.loads(path.read_text())
    for actual in observed['targets']:
        result=project(128,cut,actual['target'])
        for key in ['selectedTensorCount','selectedBytes','namedNativeLogicalBytes','hostEvidenceBytes','stateLogicalBytes','minimumFreeBeforeLoadLogicalLowerBound']:
            assert result[key]==actual[key],(cut,actual['target'],key,result[key],actual[key])
    anchors.append(dict(path=str(path),sha256=hashlib.sha256(path.read_bytes()).hexdigest()))
rows=[project(prompt,cut,target,capture) for prompt in [128,256,1024,4096,8192] for cut in [5,6,7,8,10] for target in ['full','stage0','stage1'] for capture in [True,False]]
pins=[dict(path=str(p),sha256=hashlib.sha256(p.read_bytes()).hexdigest(),bytes=p.stat().st_size) for p in [INVENTORY,CONFIG,BUDGET]]
result=dict(schema='gemma4_resident_budget_header_projection_v1',actualNativeDescriptionAnchors=anchors,matchedActualAnchorTargets=6,matchedActualFields=36,inputPins=pins,rows=rows,notActualAllocatorBounds=True,notLaunchAdmission=True,modelPayloadRead=False,nativeExecution=False)
path=Path(__file__).with_name('projection.json')
with path.open('x') as stream:json.dump(result,stream,indent=2,sort_keys=True);stream.write('\n')
for prompt in [128,1024,4096,8192]:
    print('P',prompt,'full GB',round(project(prompt,8,'full')['minimumFreeBeforeLoadLogicalLowerBound']/1e9,3))
    for cut in [5,6,7,8,10]:
        print(' cut',cut,'rank0/rank1 GB',*[round(project(prompt,cut,r)['minimumFreeBeforeLoadLogicalLowerBound']/1e9,3) for r in ['stage0','stage1']])
