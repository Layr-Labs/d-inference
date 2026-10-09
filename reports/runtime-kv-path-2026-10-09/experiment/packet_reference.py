"""Frozen-packet IO and affine baselines from the earlier CPU diagnostic.
No GPU/model execution. SHA256-validated native BF16 promotes exactly to FP32.
Original experiment helper SHA256: 48586aeffec85acfc99cd6ee05fcb7fec938ce3a418acfc2c82f4973516d17d8
"""
from __future__ import annotations
import hashlib, json, math, struct
import numpy as np
GROUP = 64
MAX_BYTES = 32 << 20
MAX_TERMS = 100_000_000

def sha(data): return hashlib.sha256(data).hexdigest()

def encode_bf16(values):
    """Finite FP32 -> BF16 round-nearest-even, expressed as little-endian bytes."""
    u=np.ascontiguousarray(values,dtype='<f4').view('<u4')
    rounded=u+np.uint32(0x7fff)+((u>>16)&np.uint32(1))
    return (rounded>>16).astype('<u2').tobytes()

def decode_bf16(raw, shape):
    u=np.frombuffer(raw,dtype='<u2').astype('<u4')<<np.uint32(16)
    return u.view('<f4').reshape(shape)

def pack_codes(codes,bits):
    flat=np.asarray(codes,dtype=np.uint8).ravel()
    # Little-endian bitstream; no padded group values are serialized.
    bit_matrix=(flat[:,None]>>np.arange(bits,dtype=np.uint8))&1
    return np.packbits(bit_matrix.ravel(),bitorder='little').tobytes()

def unpack_codes(raw,bits,count):
    packed=np.frombuffer(raw,dtype=np.uint8)
    bit_matrix=np.unpackbits(packed,bitorder='little')[:count*bits].reshape(count,bits)
    return np.sum(bit_matrix*(1<<np.arange(bits,dtype=np.uint8)),axis=1,dtype=np.uint16).astype(np.uint8)

def quantize(values,bits,axis):
    """Group affine unsigned INTb: x ~= min + scale*code, FP32 parameters."""
    moved=np.moveaxis(values,axis,-1)
    length=moved.shape[-1];groups=(length+GROUP-1)//GROUP
    padded=np.full(moved.shape[:-1]+(groups*GROUP,),np.nan,dtype=np.float32)
    padded[...,:length]=moved
    blocks=padded.reshape(moved.shape[:-1]+(groups,GROUP))
    low=np.nanmin(blocks,axis=-1).astype('<f4')
    high=np.nanmax(blocks,axis=-1).astype('<f4')
    scale=((high-low)/np.float32((1<<bits)-1)).astype('<f4')
    denom=np.where(scale==0,np.float32(1),scale)
    codes=np.clip(np.rint((blocks-low[...,None])/denom[...,None]),0,(1<<bits)-1)
    codes=np.nan_to_num(codes,nan=0).astype(np.uint8).reshape(padded.shape)[...,:length].copy()
    packed=pack_codes(codes,bits)
    decoded=unpack_codes(packed,bits,codes.size).reshape(codes.shape)
    assert np.array_equal(codes,decoded), 'Packed integer codes did not roundtrip.'
    # Load parameters from actual serialized FP32 bytes, as a restore would.
    scale_raw=scale.tobytes();bias_raw=low.tobytes()
    scale_loaded=np.frombuffer(scale_raw,dtype='<f4').reshape(scale.shape)
    bias_loaded=np.frombuffer(bias_raw,dtype='<f4').reshape(low.shape)
    group_ids=np.arange(length)//GROUP
    reconstructed=decoded.astype(np.float32)*scale_loaded[...,group_ids]+bias_loaded[...,group_ids]
    reconstructed=np.moveaxis(reconstructed,-1,axis)
    return reconstructed,{
        'bits':bits,'groupSize':GROUP,'groupAxis':axis,'quantizedElements':codes.size,
        'groups':scale.size,'packedCodeBytes':len(packed),'scaleBytes':len(scale_raw),
        'biasBytes':len(bias_raw),'storageBytes':len(packed)+len(scale_raw)+len(bias_raw),
        'packedCodesSHA256':sha(packed),'scalesSHA256':sha(scale_raw),'biasSHA256':sha(bias_raw),
        'parameterDType':'float32','parameterByteOrder':'little',
        'packing':'little-endian bitstream, tightly packed, no padded group values',
        'constantGroups':int(np.count_nonzero(scale==0)),
    }

def error(actual,reference):
    assert np.all(np.isfinite(actual)) and np.all(np.isfinite(reference))
    diff=actual.astype(np.float64)-reference.astype(np.float64)
    energy=float(np.sum(diff*diff,dtype=np.float64))
    norm=float(np.sum(reference.astype(np.float64)**2,dtype=np.float64))
    return {'linf':float(np.max(np.abs(diff))),'rmse':math.sqrt(energy/diff.size),
            'relativeL2':math.sqrt(energy/norm) if norm else (0.0 if energy==0 else None)}

def recent_attention_mass(q,k,scale,recent=128):
    result=[]
    for head in range(q.shape[1]):
        owner=head//(q.shape[1]//k.shape[1])
        logits=(k[0,owner]@q[0,head,0])*np.float32(scale)
        weights=np.exp(logits-np.max(logits),dtype=np.float32)
        weights/=np.sum(weights,dtype=np.float32)
        result.append({'queryHead':head,'recent128ProbabilityMass':float(np.sum(weights[-recent:],dtype=np.float32))})
    return result

def load_packet(root):
    packet_raw=(root/'packet.json').read_bytes(); assert len(packet_raw)<256<<10
    p=json.loads(packet_raw);assert p['schema']=='darkbloom.attention-packet.v1'
    metadata_raw=(root/p['metadata']['file']).read_bytes()
    assert len(metadata_raw)==p['metadata']['byteCount'] and sha(metadata_raw)==p['metadata']['sha256']
    md=json.loads(metadata_raw);r=md['records'][0]
    assert len(md['records'])==md['expectedOwnerCount']==md['selectedForwards']==1
    assert md['forwardSucceeded'] is True and md['sampleOutcome']=='confirmed' and not md['refusals']
    assert p['geometry']=={'attention':'full','isBidirectional':False,'mtpEnabled':False,'sharesKV':False,'visibleEnd':5585,'visibleStart':0}
    assert not any(r[x] for x in ['sinksPresent','softcapPresent','spansPresent'])
    assert r['offsetAfter']==r['offsetBefore']+1==5585 and r['storageLayerIndex']==0 and r['modelLayerIndex']==3
    assert p['capture']['evaluationStatus']=='completed'
    arrays={};raws={};total=0
    for name,d in p['tensors'].items():
        assert d['dtype']=='bfloat16' and d['byteOrder']=='little'
        f=(root/d['file']).resolve();assert f.parent==root.resolve() and f.is_file()
        raw=f.read_bytes();total+=len(raw)
        assert len(raw)==d['byteCount']==math.prod(d['shape'])*2 and sha(raw)==d['sha256']
        arr=decode_bf16(raw,d['shape']);assert np.all(np.isfinite(arr))
        assert encode_bf16(arr)==raw,'BF16 promotion identity failed.'
        arrays[name]=arr;raws[name]=raw
    assert total<=MAX_BYTES and total==p['capture']['tensorPayloadBytes']
    assert arrays['storedKeys'].shape==arrays['storedValues'].shape==(1,2,5585,256)
    assert arrays['queries'].shape==(1,16,1,256)
    for stored,incoming in [('storedKeys','incomingKeys'),('storedValues','incomingValues')]:
        assert np.array_equal(arrays[stored][:,:,-1:,:],arrays[incoming])
    scale=struct.unpack('<f',struct.pack('<I',r['scaleBits']))[0]
    assert math.isfinite(scale) and scale>0
    return p,r,arrays,raws,scale,sha(packet_raw)

def attention(q, k, v, scale):
    """B1 QL1 GQA reference, with independent K and V widths."""
    qh, kh = q.shape[1], k.shape[1]
    assert qh % kh == 0 and k.shape[:-1] == v.shape[:-1]
    assert q.shape[-1] == k.shape[-1]
    assert qh * k.shape[-2] * k.shape[-1] <= MAX_TERMS
    result = np.empty(q.shape[:-1] + (v.shape[-1],), dtype=np.float32)
    for head in range(qh):
        owner = head // (qh // kh)
        logits = (k[0, owner] @ q[0, head, 0]) * np.float32(scale)
        weights = np.exp(logits - np.max(logits), dtype=np.float32)
        weights /= np.sum(weights, dtype=np.float32)
        result[0, head, 0] = weights @ v[0, owner]
    assert np.all(np.isfinite(result))
    return result
