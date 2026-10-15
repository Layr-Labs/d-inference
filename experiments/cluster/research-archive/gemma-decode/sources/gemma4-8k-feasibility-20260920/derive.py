"""Retained-report arithmetic projection only. No native, model or remote execution."""
from pathlib import Path
import hashlib,json,re
ROOT=Path(__file__).resolve().parent
BASE=ROOT.parent/'gemma4-execution-20260920'
CFG=Path('/Users/developer/DarkbloomDev/d-inference/libs/darkbloom-cluster/Tests/StageMetadataChecks/Inputs/config.json')
PAGE=16384
pins={}
def read(p):
 b=p.read_bytes();assert len(b)<4*1024**2;pins[str(p)]={'sha256':hashlib.sha256(b).hexdigest(),'bytes':len(b)};return json.loads(b)
c=read(CFG)['text_config']
def bound(n):
 if n>PAGE:n=(n+PAGE-1)//PAGE*PAGE
 return n+min(n-1,2*PAGE-1)
def project(cut,chunk,mode,prompt=8192,lookahead=True,window_bound=False):
 case='p4096-cut7-c64-serial-v7' if cut==7 else 'p1024-cut6-c128-correctness-1'
 folder='solo/full' if mode=='full' else 'pair/'+mode
 v=read(BASE/'cases'/case/folder/'terminal.json')['result'];s=v['resources'];oldp=v['job']['promptCount'];oldm=v['job']['chunkSize'];oldn=oldp+16;n=prompt+16
 assert all(bound(x['bytes'])==b for x,b in zip(s['namedArrays'],s['namedAllocationBounds']))
 arrays=[]
 for x in s['namedArrays']:
  name=x['name'];bytes=x['bytes'];a=b=1
  match=re.fullmatch(r'layer([0-9]+):(.+)',name)
  if name.startswith(('constantCast:','headCast:')):pass
  elif match:
   layer=int(match[1]);kind=match[2];full=c['layer_types'][layer]=='full_attention'
   if kind in ('keys','values') and full:a,b=n,oldn
   elif kind in ('keys','values','oldKeys','oldValues','position','capturedPosition','queryPosition','routerScale','probeKeys','probeValues'):pass
   elif kind in ('chunkKeys','chunkValues'):a,b=c['sliding_window']-1+chunk,c['sliding_window']-1+oldm
   elif kind in ('attentionKCopy','attentionVCopy'):a,b=(min(n,c['sliding_window']-1+chunk) if window_bound and not full else n),oldn
   elif kind in ('attentionScores','attentionProbabilities','attentionMask'):a,b=chunk*(min(n,c['sliding_window']-1+chunk) if window_bound and not full else n),oldm*oldn
   else:a,b=chunk,oldm
  elif name in ('logits','float32Logits','softcapTemporary','samplingRow'):pass
  elif name in ('inputIDs','embeddingGatherWeight','embeddingGatherScales','embeddingGatherBiases','embeddingDequantized','residual','ownedResidualCopy','boundaryExport'):a,b=chunk,oldm
  else:raise ValueError(name)
  assert bytes*a%b==0;arrays.append(dict(name=name,bytes=bytes*a//b))
 globals=range(30) if mode=='full' else range(cut) if mode=='stage0' else range(cut,30)
 state=sum(2*(n if c['layer_types'][g]=='full_attention' else c['sliding_window'])*(c['num_global_key_value_heads'] if c['layer_types'][g]=='full_attention' else c['num_key_value_heads'])*(c['global_head_dim'] if c['layer_types'][g]=='full_attention' else c['head_dim'])*4 for g in globals)
 # Capture remains enabled, F32 ceiling retained; n always exceeds sliding window here.
 host=state+8*262144*4+2*chunk*2816*4+8388608+32768
 extraNative=extraHost=0
 if lookahead and mode!='full':
  extraHost=65536
  if mode=='stage0':
   arrays.append(dict(name='lookaheadPreparedBoundary',bytes=chunk*2816*4));extraNative=bound(chunk*2816*4);extraHost+=chunk*2816*4
  host+=extraHost
 logical=sum(x['bytes'] for x in arrays);native=sum(bound(x['bytes']) for x in arrays)
 selected=v['sourceLoad']['loadedTensorBytes'];selectedBound=sum(s['selectedAllocationBounds']);largest=v['sourceLoad']['largestHostTensorBytes'];scratch=8404992
 initial=max(6*1024**3,selectedBound+largest+bound(largest)+scratch+native+host+4*1024**3)
 initialLogical=max(6*1024**3,selected+largest*2+scratch+logical+host+4*1024**3)
 loaded=max(6*1024**3,native+host+4*1024**3)
 return dict(cut=cut,chunk=chunk,prompt=prompt,mode=mode,policy='oneChunkLookahead' if lookahead and mode!='full' else 'serial',capture=True,isolatedWindowBoundDraft=window_bound,
  selectedBytes=selected,selectedAllocationBounds=selectedBound,namedNativeLogicalBytes=logical,namedNativeReserveBytes=native,hostEvidenceBytes=host,stateLogicalBytes=state,
  initialFreeLogicalLowerBound=initialLogical,initialFreeWithRetained16KiBAllocatorPolicy=initial,loadedFreeRequirement=loaded,
  extraPrefillNativeBytes=extraNative,extraPrefillHostBytes=extraHost,
  baselineSource=case,baselinePrompt=oldp,baselineChunk=oldm,baselineObservedMinFree=s['minimumActualFreeBytes'],baselineObservedNativePeak=s['maximumObservedNativePeakBytes'])
rows=[project(cut,chunk,mode) for cut,chunk in [(7,64),(6,128),(6,64)] for mode in ['full','stage0','stage1']]
# An arithmetic replay of existing accepted 4K rows checks the transformation and F32 reserve convention.
for mode in ['full','stage0','stage1']:
 x=project(7,64,mode,prompt=4096,lookahead=False);old=read(BASE/'cases/p4096-cut7-c64-serial-v7'/('solo/full' if mode=='full' else 'pair/'+mode)/'terminal.json')['result']['resources']
 assert x['namedNativeReserveBytes']==old['namedNativeReserveBytes'] and x['hostEvidenceBytes']==old['hostEvidenceReserveBytes'] and x['stateLogicalBytes']==old['stateLogicalBytes']
for name in ['Gemma4BenchmarkResourceBudget.swift','Gemma4BenchmarkResourceOwner.swift','Gemma4BenchmarkInput.swift','Gemma4BenchmarkWire.swift','Gemma4BenchmarkWirePayload.swift','Gemma4BenchmarkDriver.swift','Gemma4BenchmarkRuntime.swift']:
 key='libs/darkbloom-cluster/Sources/DarkbloomClusterRuntime/'+name
 p=BASE/'build/before-full-model-ep'/key
 if not p.exists():p=BASE/'build/workspace'/key
 b=p.read_bytes();pins[str(p)]={'sha256':hashlib.sha256(b).hexdigest(),'bytes':len(b)}
p=BASE/'build/applied-uncached-sidecars.json';applied=read(p);mapped={x['path']:x for x in applied['files']}
for path,info in list(pins.items()):
 if '/libs/darkbloom-cluster/Sources/DarkbloomClusterRuntime/' in path:
  key='libs/darkbloom-cluster/Sources/DarkbloomClusterRuntime/'+Path(path).name
  assert key in mapped and info['sha256']==mapped[key]['sha256']
b=read(BASE/'build/GemmaResidentBenchmark-build-6.json');assert b['sourcesSHA256']==hashlib.sha256(p.read_bytes()).hexdigest() and b['nativeSHA256']=='6115f51db204f8afe59b1e6b68d47074c7cad14bfde11e5acda477c290305034'
out=dict(schema='gemma4_8k_source_budget_projection_v1',predictionOnly=True,nativeExecuted=False,compilerExecuted=False,remoteExecuted=False,allocatorPageBytes=PAGE,nativeBuildSHA256=b['nativeSHA256'],projectedCandidates=rows,inputPins=pins)
(ROOT/'prediction.json').write_text(json.dumps(out,sort_keys=True,indent=2)+'\n')
draftRows=[project(cut,chunk,mode,window_bound=True) for cut,chunk in [(7,64),(6,128),(6,64)] for mode in ['full','stage0','stage1']]
(ROOT/'window-bound-prediction.json').write_text(json.dumps(dict(out,projectedCandidates=draftRows,nativeBuildSHA256=None,baselineNativeBuildSHA256=b['nativeSHA256'],requiresNewBuildAndQualification=True),sort_keys=True,indent=2)+'\n')
for x in rows:print(x['cut'],x['chunk'],x['mode'],'initial',x['initialFreeWithRetained16KiBAllocatorPolicy'],'loaded',x['loadedFreeRequirement'],'named',x['namedNativeReserveBytes'],'host',x['hostEvidenceBytes'])
