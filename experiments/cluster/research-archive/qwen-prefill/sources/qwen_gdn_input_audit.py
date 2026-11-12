"""CPU-only raw GDN projection/layout oracle; no MLX import or native execution."""
import hashlib
import json
import math
from pathlib import Path
import struct


def require(condition, message):
    if not condition: raise ValueError(message)


def digest(data): return hashlib.sha256(data).hexdigest()


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False, allow_nan=False).encode()


def f32(value):
    require(type(value) in (int,float) and math.isfinite(value), 'Nonfinite/bool tensor value')
    result=struct.unpack('<f',struct.pack('<f',value))[0]
    require(math.isfinite(result),'Float32 overflow')
    return result


def logical_bytes(values,dtype):
    require(dtype in ('float32','float16','bfloat16'),'Unsupported floating capture dtype')
    data=bytearray()
    for raw in values:
        value=f32(raw)
        if dtype=='float32': data.extend(struct.pack('<f',value))
        elif dtype=='float16':
            packed=struct.pack('<e',value)
            require(struct.unpack('<e',packed)[0]==value,'Value is not exactly float16');data.extend(packed)
        else:
            bits=struct.unpack('<I',struct.pack('<f',value))[0]
            require(bits&65535==0,'Value is not exactly BF16');data.extend(struct.pack('<H',bits>>16))
    return bytes(data)


def capture(value):
    require(isinstance(value,dict),'Tensor capture must be object')
    shape=value.get('shape');values=value.get('values')
    require(isinstance(shape,list) and shape and all(type(x)is int and x>0 for x in shape),'Bad capture shape')
    require(math.prod(shape)<=4*1024*1024 and isinstance(values,list) and len(values)==math.prod(shape),'Incomplete capture')
    raw=logical_bytes(values,value['dtype'])
    require(digest(raw)==value['logicalBytesSHA256'],'Captured logical bytes hash differs')
    return [f32(v) for v in values]


def metrics(left,right):
    require(len(left)==len(right)>0,'Metric geometry differs')
    a,b=[f32(v) for v in left],[f32(v) for v in right]
    d=[y-x for x,y in zip(a,b)]
    squared=math.fsum(x*x for x in d)
    return dict(comparedValues=len(a),differingValues=sum(x!=y for x,y in zip(a,b)),exact=a==b,
        maximumAbsoluteError=max(map(abs,d)),rootMeanSquareError=math.sqrt(squared/len(a)),
        relativeRMSError=math.sqrt(squared/max(math.fsum(x*x for x in a),1e-30)))


def components(text,rank=None):
    # Explicit model semantics, not the native report's supplied intervals.
    k=text['linear_num_key_heads']*text['linear_key_head_dim']
    v=text['linear_num_value_heads']*text['linear_value_head_dim']
    n=text['linear_num_value_heads']
    require(k%2==v%2==n%2==0,'Illegal two-rank dimensions')
    result=[];offset=local=0
    for name,width in [('q',k),('k',k),('v',v),('z',v),('b',n),('a',n)]:
        lo=offset if rank is None else offset+rank*width//2
        hi=offset+width if rank is None else lo+width//2
        result.append(dict(name=name,sourceRows=[lo,hi],localRows=[local,local+hi-lo]))
        offset+=width;local+=hi-lo
    return result


def selections(text,rank=None):
    k=text['linear_num_key_heads']*text['linear_key_head_dim'];v=text['linear_num_value_heads']*text['linear_value_head_dim'];n=text['linear_num_value_heads']
    def selected(width,offset=0):
        return [offset,offset+width] if rank is None else [offset+rank*width//2,offset+(rank+1)*width//2]
    return [dict(name='in_proj_'+name,axis=0,ranges=ranges) for name,ranges in [
        ('qkv',[[0,2*k+v]] if rank is None else [selected(k),selected(k,k),selected(v,2*k)]),
        ('z',[selected(v)]),('b',[selected(n)]),('a',[selected(n)])]]


def columns(values,width,interval):
    lo,hi=interval;require(0<=lo<hi<=width and len(values)%width==0,'Invalid component interval')
    return [v for row in range(len(values)//width) for v in values[row*width+lo:row*width+hi]]


def projection_oracle(report,text):
    """Reconstruct selected component outputs and compute error without native metrics."""
    source=report['sourceProjections']
    require(digest(canonical(source))==report['sourceProjectionsSHA256'],'Source projection metadata hash differs')
    hidden=report['normalizedInput'];capture(hidden)
    require(hidden['shape']==[1,report['chunkSize'],text['hidden_size']],'Normalized input geometry differs')
    def identity(record,shape,dtype):
        require(set(record)=={'shape','dtype','logicalBytesSHA256'} and record['shape']==shape
            and record['dtype']==dtype and isinstance(record['logicalBytesSHA256'],str)
            and len(record['logicalBytesSHA256'])==64 and all(c in '0123456789abcdef' for c in record['logicalBytesSHA256']), 'Malformed parameter identity')
    names=['in_proj_qkv','in_proj_z','in_proj_b','in_proj_a']
    require([x['name'] for x in source]==names,'Source projection order differs')
    prefix=report['inputNormPath'].removesuffix('.input_layernorm')+'.linear_attn.'
    choices=selections(text)
    for projection,choice in zip(source,choices):
        rows=choice['ranges'][0][1];h=text['hidden_size']
        require(projection['modulePath']==prefix+projection['name'] and projection['inputWidth']==h
            and projection['outputRows']==rows and projection['bits']==4 and projection['groupSize']==64
            and projection['mode']=='affine','Source projection metadata differs')
        identity(projection['weight'],[rows,h//8],'uint32')
        for name in ('scales','biases'):identity(projection[name],[rows,h//64],hidden['dtype'])
    identity(report['inputNormWeight'],[text['hidden_size']],hidden['dtype'])
    for rank,projection in [(None,report['full']),*enumerate(report['ranks'])]:
        width=components(text,rank)[-1]['localRows'][1];h=text['hidden_size']
        identity(projection['fusedWeight'],[width,h//8],'uint32')
        for name in ('fusedScales','fusedBiases'):identity(projection[name],[width,h//64],hidden['dtype'])
    first=report['firstLogits'];logits=capture(first)
    require(math.prod(first['shape'])==text['vocab_size'],'Incomplete first logits')
    require(logits.index(max(logits))==report['firstLogitArgmaxToken'],'First logit argmax differs')
    full=report['full'];full_values=capture(full['output']);width=full['output']['shape'][-1]
    full_components=components(text)
    require(full.get('rank') is None and full['components']==full_components,'Full component layout differs')
    require(full['selections']==selections(text) and full['selectionSHA256']==digest(canonical(full['selections'])),'Full selection differs')
    require(full['output']['shape']==[1,report['chunkSize'],full_components[-1]['localRows'][1]],'Full output geometry differs')
    require(len(report['ranks'])==2,'Missing rank projections')
    results=[];reassembled=[None]*len(full_values)
    for rank,record in enumerate(report['ranks']):
        expected=components(text,rank);actual=capture(record['output']);rank_width=expected[-1]['localRows'][1]
        require(record['rank']==rank and record['components']==expected,'Rank component layout differs')
        require(record['selections']==selections(text,rank) and record['selectionSHA256']==digest(canonical(record['selections'])),'Rank selection differs')
        require(record['output']['shape']==[1,report['chunkSize'],rank_width],'Rank output geometry differs')
        require(record['output']['dtype']==full['output']['dtype']==hidden['dtype'],'Unexpected projection arithmetic dtype')
        per=[]
        for comp in expected:
            left=columns(full_values,width,comp['sourceRows']);right=columns(actual,rank_width,comp['localRows'])
            row_width=comp['localRows'][1]-comp['localRows'][0]
            per.append(dict(name=comp['name'],aggregate=metrics(left,right),
                rows=[metrics(left[i:i+row_width],right[i:i+row_width]) for i in range(0,len(left),row_width)]))
            if full['output']['dtype']=='bfloat16':per[-1]['bfloat16Steps']=bf16_steps(left,right)
            for row in range(report['chunkSize']):
                lo,hi=comp['sourceRows'];a,b=comp['localRows']
                indices=range(row*width+lo,row*width+hi)
                require(all(reassembled[i] is None for i in indices),'Overlapping component ownership')
                reassembled[row*width+lo:row*width+hi]=actual[row*rank_width+a:row*rank_width+b]
        results.append(dict(rank=rank,components=per))
    require(all(v is not None for v in reassembled),'Rank components do not cover full projection')
    return dict(ranks=results,reassembled=metrics(full_values,reassembled),
        firstLogitArgmaxToken=report['firstLogitArgmaxToken'],component_layout_independently_derived=True,
        not_a_cpu_reimplementation_of_metal_quantized_matmul=True)



def bf16_steps(left,right):
    def ordered(value):
        bits=struct.unpack('<I',struct.pack('<f',f32(value)))[0]
        require(bits&65535==0,'BF16 metric received inexact value');word=bits>>16
        return 32768-(word&32767) if word&32768 else 32768+word
    values=[abs(ordered(a)-ordered(b)) for a,b in zip(left,right)]
    require(len(left)==len(right)>0,'BF16 step geometry differs')
    return dict(definition='absolute distance between ordered finite BF16 values; signed zeros coincide',
        maximumAbsoluteSteps=max(values),meanAbsoluteSteps=sum(values)/len(values),
        oneStepDifferences=sum(v==1 for v in values),greaterThanOneStepDifferences=sum(v>1 for v in values))


def verify_native_differences(native,oracle):
    require(isinstance(native,list) and len(native)==12,'Missing native component comparisons')
    for observed,(rank,comp) in zip(native,[(r['rank'],c) for r in oracle['ranks'] for c in r['components']]):
        m=comp['aggregate']
        expected=dict(rank=rank,component=comp['name'],comparedValues=m['comparedValues'],
            differingValues=m['differingValues'],exactValues=m['exact'])
        for key,value in expected.items():
            require(type(observed.get(key)) is type(value) and observed[key]==value,'Native difference metadata differs: '+key)
        require(type(observed['maximumAbsoluteError']) in (int,float) and observed['maximumAbsoluteError']==m['maximumAbsoluteError'],'Native maximum error differs')
        for key in ('rootMeanSquareError','relativeRMSError'):
            require(type(observed[key]) in (float,int) and math.isclose(observed[key],m[key],rel_tol=1e-12,abs_tol=1e-15),'Native RMS differs')
        if 'bfloat16Steps' in comp:
            require(observed['bfloat16Steps']==comp['bfloat16Steps'],'Native BF16 steps differ')
        else:require(observed.get('bfloat16Steps') is None,'F32 reported BF16 step metric')

def checkpoint_headers(model):
    tensors={}
    for path in sorted(Path(model).glob('*.safetensors')):
        with path.open('rb') as f:
            length=struct.unpack('<Q',f.read(8))[0];require(0<length<=16*1024**2,'Unbounded safetensors metadata')
            raw=f.read(length);require(len(raw)==length,'Truncated safetensors metadata');header=json.loads(raw)
        for name,tensor in header.items():
            if name=='__metadata__':continue
            require(name not in tensors,'Duplicate safetensor key')
            tensors[name]=dict(tensor,path=path,base=8+length)
    return tensors


def selected_source_bytes(tensor,ranges):
    shape=tensor['shape'];dtype=tensor['dtype'];width={'BF16':2,'F16':2,'F32':4,'U32':4}[dtype]
    require(len(shape) in (1,2),'Only norm vectors and projection matrices are supported')
    lo,hi=tensor['data_offsets'];row_bytes=math.prod(shape[1:])*width
    require(hi-lo==math.prod(shape)*width,'Safetensor offsets differ')
    data=bytearray()
    with tensor['path'].open('rb') as f:
        for a,b in ranges:
            require(type(a)is int and type(b)is int and 0<=a<b<=shape[0],'Invalid selected source rows')
            f.seek(tensor['base']+lo+a*row_bytes);part=f.read((b-a)*row_bytes)
            require(len(part)==(b-a)*row_bytes,'Truncated selected source bytes');data.extend(part)
    require(dtype!='F16','This exact registered artifact has BF16 metadata; F16 conversion is outside this byte oracle')
    return bytes(data),{'BF16':'bfloat16','F32':'float32','U32':'uint32'}[dtype],[sum(b-a for a,b in ranges),*shape[1:]]


def verify_real_weight_bytes(report,model,text):
    tensors=checkpoint_headers(model);source=report['sourceProjections'];result=[]
    require([x['name'] for x in source]==['in_proj_qkv','in_proj_z','in_proj_b','in_proj_a'],'Source projection order differs')
    norm_path='language_model.model.layers.0.input_layernorm'
    require(report['inputNormPath']==norm_path,'Input norm path differs')
    norm=tensors[norm_path+'.weight'];data,dtype,shape=selected_source_bytes(norm,[[0,text['hidden_size']]])
    require(report['inputNormWeight']==dict(shape=shape,dtype=dtype,logicalBytesSHA256=digest(data)),'Actual input norm weight differs from source')
    require(f32(report['inputNormEpsilon'])==f32(text['rms_norm_eps']),'Input norm epsilon differs')
    result.append(dict(rank=None,parameter='input_norm_weight',selectedBytes=len(data),shape=shape,dtype=dtype,logicalBytesSHA256=digest(data)))
    for projection,choice in zip(source,selections(text)):
        require(projection['modulePath']=='language_model.model.layers.0.linear_attn.'+projection['name'],'Source path differs')
        require(projection['bits']==4 and projection['groupSize']==64 and projection['mode']=='affine','Unsupported quantization')
        require(projection['inputWidth']==text['hidden_size'] and projection['outputRows']==choice['ranges'][0][1],'Source geometry differs')
        for suffix in ('weight','scales','biases'):
            tensor=tensors[projection['modulePath']+'.'+suffix]
            data,dtype,shape=selected_source_bytes(tensor,choice['ranges'])
            require(projection[suffix]==dict(shape=shape,dtype=dtype,logicalBytesSHA256=digest(data)),'Source logical bytes differ')
    for rank,record in [(None,report['full']),*enumerate(report['ranks'])]:
        for suffix,fused in [('weight','fusedWeight'),('scales','fusedScales'),('biases','fusedBiases')]:
            data=bytearray();rows=0;dtype=cols=None
            for projection,choice in zip(source,selections(text,rank)):
                part,part_dtype,shape=selected_source_bytes(tensors[projection['modulePath']+'.'+suffix],choice['ranges'])
                require(dtype is None or dtype==part_dtype,'Mixed fused dtypes');require(cols is None or cols==shape[1],'Mixed fused columns')
                data.extend(part);rows+=shape[0];dtype=part_dtype;cols=shape[1]
            actual=dict(shape=[rows,cols],dtype=dtype,logicalBytesSHA256=digest(data))
            require(record[fused]==actual,'Selected fused source bytes differ')
            result.append(dict(rank=rank,parameter=suffix,selectedBytes=len(data),**actual))
    return result
