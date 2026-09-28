"""CPU validation of captured state namespaces and finite native logit bytes."""
import math
import struct
from .common import FLOATS,WIDTH,canonical,digest,exact,integer,require,sha,shape_bytes
from . import stage_ranges


def logit_bytes(record,vocabulary):
    require(set(record)=={'shape','dtype','byteCount','logicalBytesSHA256','values'},'Logit schema differs')
    exact(record['shape'],[1,vocabulary],'Logits must retain complete vocabulary')
    dtype=record['dtype'];require(dtype in FLOATS,'Unsupported native logit dtype')
    require(integer(record['byteCount'])==vocabulary*WIDTH[dtype],'Logit byte count differs')
    values=record['values'];require(isinstance(values,list) and len(values)==vocabulary,'Missing logit values')
    data=bytearray()
    for value in values:
        require(type(value)in(int,float) and math.isfinite(value),'Nonfinite/bool logit')
        try:
            packed=struct.pack('<f',value);floating=struct.unpack('<f',packed)[0]
            require(math.isfinite(floating),'Float32 serialization overflow')
            if dtype=='bfloat16':
                bits=struct.unpack('<I',packed)[0]
                require(bits&65535==0,'Value is not exactly native BF16');data.extend(struct.pack('<H',bits>>16))
            elif dtype=='float16':
                half=struct.pack('<e',floating)
                require(struct.unpack('<e',half)[0]==floating,'Value is not exactly native Float16');data.extend(half)
            else:data.extend(packed)
        except (OverflowError,struct.error) as error:raise ValueError('Native logit overflow') from error
    require(digest(data)==sha(record['logicalBytesSHA256']),'Native logit byte hash differs')
    return bytes(data)


def state_entries(entries,text,rank,tokens,stage_cut=None):
    layers=integer(text['num_hidden_layers'],2,128)
    start,end=stage_ranges.ranges(text,stage_cut)[integer(rank,0,1)]
    expected={}
    for layer in range(start,end):
        if (layer+1)%text['full_attention_interval']==0:
            kv=[1,text['num_key_value_heads'],tokens,text['head_dim']]
            parts=[('kv.keys',kv,None),('kv.values',kv,None),('kv.position_offsets',[1],'int32')]
        else:
            channels=2*text['linear_num_key_heads']*text['linear_key_head_dim']+text['linear_num_value_heads']*text['linear_value_head_dim']
            parts=[('conv',[1,text['linear_conv_kernel_dim']-1,channels],None),
                   ('ssm',[1,text['linear_num_value_heads'],text['linear_value_head_dim'],text['linear_key_head_dim']],'float32')]
        for component,shape,dtype in parts:expected[(layer,component)]=(shape,dtype)
    require(isinstance(entries,list) and len(entries)==len(expected),'Incomplete state namespace')
    require(entries==sorted(entries,key=lambda x:(x['globalLayerIndex'],x['component'])),'State entries must be ordered')
    seen=set();total=0;identities=[]
    for entry in entries:
        require(set(entry)=={'globalLayerIndex','component','shape','dtype','byteCount','sha256'},'State schema differs')
        key=(integer(entry['globalLayerIndex'],0,layers-1),entry['component'])
        require(key in expected and key not in seen,'Unknown/duplicate state key');seen.add(key)
        shape,dtype=expected[key];exact(entry['shape'],shape,'State shape differs from local/global configuration')
        require(entry['dtype']==dtype if dtype else entry['dtype']in FLOATS,'Wrong state dtype class')
        size=shape_bytes(shape,entry['dtype'],allow_empty_conv=key[1]=='conv')
        require(integer(entry['byteCount'])==size,'State byte count differs');total+=size
        if size==0:require(entry['sha256']==digest(b''),'Empty convolution history hash differs')
        identities.append(f"{key[0]}|{key[1]}|{shape}|{entry['dtype']}|{size}|{sha(entry['sha256'])}")
    fingerprint=digest('\n'.join(['cbv2-owned-state-v1',f'tokens={tokens}']+identities).encode())
    return total,fingerprint
