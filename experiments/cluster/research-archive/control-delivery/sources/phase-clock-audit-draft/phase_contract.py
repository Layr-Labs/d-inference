"""Small CPU metadata contract; no model inventory or numerical oracle import."""
import hashlib
import importlib.util
import json
import math
from pathlib import Path
import re
import uuid

ROOT=Path(__file__).resolve().parent.parent
PROFILE='long_prefill_8k_v1'
PROFILE_FP='2b7f484488df61c4f6042acfb472a8099828c8a6246819501c88d4f6e07bcc0b'
U64=2**64-1
MAX_STDOUT=16*1024**2
MAX_TRACE=512*1024
PINNED={
 'phase-output-draft/Tracing/QwenPrefillPhaseCapture.swift':'6af6bef5960333370db8f8bcf129d43a529958456ccbffe05d88f6784e489436',
 'phase-output-draft/Tracing/QwenPrefillPhaseFile.swift':'9f8bc2f68fda1691a41f052e502287170434b32a83e8d0b1e729a840fd40ecd9',
 'phase-clock-draft/manifest.json':'bce1c69934ff9ec035e450be86e376d2bf1939069de2d9e0ec812f88e99b6f73',
 'phase-clock-draft/Tracing/QwenPrefillPhaseTypes.swift':'88ed21e2b9d8cffc189ef42f43b04db4e9327971eaa73582505d6b144a182d25',
 'phase-clock-draft/Tracing/QwenPrefillPhaseRecorder.swift':'ea3e3931e34afc589b83b69971c9f94ec2ba989ca850739e42d1036feddd4256',
 'phase-clock-draft/proposed-owner-sources/QwenLongPrefillRankTrace.swift':'d949b12fb9773c7ca3b2104e41d213006c3123fc364eb42af605e101a2f83bd1',
 'phase-clock-draft/proposed-owner-sources/QwenLongPrefillRankRequest.swift':'35f0659eecdb177c27590186e1628fdc017e99d215629722e6683b57ef53e5f9',
 'phase-clock-draft/proposed-owner-sources/QwenLongPrefillSoloRequest.swift':'0ce471c0c560f9f95ce80ae103cb3502d9432535e07749a54a73c398ec0433bf',
 'long-prefill-rank-audit-draft/rank_trace.py':'ce6ea792b84fccf69434369841ed214aac8f5fcfa8dd0ad38c38e7734843b67d',
 'long-prefill-geometry-draft/QwenLayerStagePrefillProfile.swift':'941a474390f13c1df7dca8aa894f31b1bd26303cb8932931f3ecb9491206c9d1',
}
_TIMELINE=None


def require(ok,message):
    if not ok:raise ValueError(message)


def sha(data):return hashlib.sha256(data).hexdigest()
def canonical(value):return json.dumps(value,sort_keys=True,separators=(',',':'),allow_nan=False).encode()


def integer(value,low=0,high=U64):
    require(type(value) is int and low<=value<=high,'Invalid bounded integer');return value


def exact(actual,wanted,path='value'):
    require(type(actual) is type(wanted),path+' type differs')
    if type(wanted) is dict:
        require(set(actual)==set(wanted),path+' fields differ')
        for key in wanted:exact(actual[key],wanted[key],path+'.'+key)
    elif type(wanted) is list:
        require(len(actual)==len(wanted),path+' length differs')
        for i,(a,b) in enumerate(zip(actual,wanted)):exact(a,b,path+'['+str(i)+']')
    else:require(actual==wanted,path+' differs')


def fields(value,keys,label):
    require(type(value) is dict and set(value)==set(keys.split()),label+' schema differs')


def flags(value,**wanted):
    for key,item in wanted.items():exact(value.get(key),item,key)


def read(path,limit):
    with Path(path).open('rb') as stream:data=stream.read(limit+1)
    require(0<len(data)<=limit,'Input size exceeds bound');return data


def parse(data):
    require(type(data) is bytes,'Raw UTF8 bytes required')
    depth=0;quoted=False;escaped=False
    for byte in data:
        if quoted:
            if escaped:escaped=False
            elif byte==92:escaped=True
            elif byte==34:quoted=False
        elif byte==34:quoted=True
        elif byte in (91,123):
            depth+=1;require(depth<=16,'JSON nesting exceeds bound')
        elif byte in (93,125):depth-=1
    def pairs(items):
        value={}
        for k,v in items:require(k not in value,'Duplicate JSON key');value[k]=v
        return value
    def constant(_):raise ValueError('Nonfinite JSON number')
    def floating(text):
        value=float(text);require(math.isfinite(value),'Nonfinite JSON float');return value
    return json.loads(data.decode('utf8'),object_pairs_hook=pairs,parse_constant=constant,parse_float=floating,
        parse_int=lambda text:-0.0 if text=='-0' else int(text))


def stdout_rows(raw):
    require(type(raw) is bytes and 0<len(raw)<=MAX_STDOUT,'Stdout exceeds bound')
    rows=raw.splitlines();require(len(rows)==2 and all(rows),'Exactly ready and final JSONL required')
    return [parse(row) for row in rows]


def verify_pins():
    out={}
    for name,pin in PINNED.items():
        data=read(ROOT/name,128*1024);require(sha(data)==pin,'Source expectation pin changed: '+name)
        out[name]=dict(sha256=pin,byteCount=len(data))
    return out


def timeline():
    global _TIMELINE
    if _TIMELINE is None:
        name='long-prefill-rank-audit-draft/rank_trace.py';path=ROOT/name
        require(sha(read(path,65536))==PINNED[name],'Pure scalar timeline helper changed')
        spec=importlib.util.spec_from_file_location('phase_pinned_scalar_timeline',path)
        _TIMELINE=importlib.util.module_from_spec(spec);spec.loader.exec_module(_TIMELINE)
    return _TIMELINE


def request(value):
    fields(value,'request vocabularySize promptTokenIDs teacherTokenIDs steps fingerprint','recorded request')
    spec=value['request'];fields(spec,'profile requestID batchSize promptCount chunkSize outputCount','profiled request')
    rid=spec['requestID'];require(type(rid) is str and re.fullmatch('[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}',rid),'Invalid request UUID')
    uid=str(uuid.UUID(rid));exact(spec,dict(profile=PROFILE,requestID=rid,batchSize=1,promptCount=8192,chunkSize=512,outputCount=1))
    tokens=value['promptTokenIDs'];require(type(tokens) is list and len(tokens)==8192,'8192 prompt IDs required')
    for token in tokens:integer(token,0,248319)
    exact(value['vocabularySize'],248320);exact(value['teacherTokenIDs'],[])
    steps=[]
    for i in range(16):
        frame=dict(sequence=i,phase='prefill',tokenOffset=i*512,tokenCount=512,finalPromptChunk=i==15)
        steps.append(dict(frame=frame,tokenIDs=tokens[i*512:(i+1)*512],committedTokens=(i+1)*512))
    exact(value['steps'],steps,'recorded chunk history')
    simple=sha('\n'.join(['qwen-stage-profiled-prefill-request-v1',PROFILE,PROFILE_FP,uid,'batch=1','prompt=8192','chunk=512','output=1']).encode())
    history=sha('\n'.join(['qwen-layer-stage-profiled-prefill-recorded-request-v1',PROFILE,PROFILE_FP,simple,
        'vocabulary=248320','prompt='+','.join(map(str,tokens)),'teacher=']).encode())
    exact(value['fingerprint'],history,'recorded prompt fingerprint')
    return dict(simple=simple,history=history,steps=steps,uuid=uid)


def solo_events():
    result=[]
    def add(name,tokens,frame=None):
        row=dict(ordinal=len(result),phase=name,committedTokens=tokens)
        if frame is not None:row['frameSequence']=frame
        result.append(row)
    for name in ['request.ready','freshRequest.begin','freshRequest.created']:add(name,0)
    for i in range(16):add('prefill.begin',i*512,i);add('prefill.committed',(i+1)*512,i)
    for name in ['selection.begin','selection.completed','diagnostics.begin','diagnostics.completed','retirement.begin','request.closed']:add(name,8192)
    require(len(result)==41,'Source-derived solo count differs');return result


def primary_clock(value,role):
    numbers='startUptimeNanoseconds stopUptimeNanoseconds elapsedNanoseconds promptTokensPerFirstTokenSecond postStopThroughRequestCloseNanoseconds'
    wanted=timeline().timing_flags() if role=='rank0' else dict(includesFreshRequestState=True,
        includesFiniteArgmaxAndScalarReadback=True,includesBoundedCommitMetadata=True,includesTransport=False,
        excludesLoadReadinessFinalCaptureAndRetirement=True)
    require(type(value) is dict and set(value)==set(numbers.split())|set(wanted),'Primary timing schema differs')
    flags(value,**wanted)
    start=integer(value['startUptimeNanoseconds']);stop=integer(value['stopUptimeNanoseconds'])
    elapsed=integer(value['elapsedNanoseconds'],1);post=integer(value['postStopThroughRequestCloseNanoseconds'])
    require(start<stop and stop-start==elapsed and stop+post<=U64,'Primary local UInt64 clock arithmetic differs')
    rate=value['promptTokensPerFirstTokenSecond'];require(type(rate) in (int,float) and math.isfinite(rate)
        and rate==8192e9/float(elapsed),'Primary diagnostic rate arithmetic differs')
    return dict(start=start,stop=stop,closed=stop+post)
