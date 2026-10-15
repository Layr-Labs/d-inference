"""Exact frozen full-target binding/read arithmetic, extracted unchanged."""
import math
import struct
from recorded_math import WIDTH,canonical,digest,equal,require,sha_string

def text_hash(parts):
    return digest('\n'.join(parts).encode())

def integer(value, low=0, high=2**63-1):
    require(type(value) is int and low <= value <= high, 'Invalid bounded integer')
    return value

def binding(value, load):
    require(value['target']==load['target']=='full-reference' and value['maximumTokens']==144 and value['maximumChunkTokens']==64
            and value['probePrefillTokens']==2 and value['probeDecodeTokens']==1
            and value['selectedTensorCount']==1339, 'Full target state binding differs')
    for key in ('planSHA256','artifactSHA256','configurationSHA256','parameterLayoutSHA256'):
        require(value[key]==load[key], 'Binding differs from actual source load: '+key); sha_string(value[key])
    require(value['selectedBytes']==load['loadedTensorBytes']
            and value['readAccountingSHA256']==digest(canonical(load['readAccounting'])), 'Actual read accounting differs')
    rows=['attention-state-layout-v1','maximumTokens=144','maximumChunkTokens=64','prefix=false','speculation=false']
    require(len(value['layers'])==30,'Missing full state layers')
    for index,layer in enumerate(value['layers']):
        full=index%6==5; dtype=layer['dtype']
        require(dtype in ('float16','bfloat16','float32'),'Unknown observed KV dtype')
        equal(layer,dict(localIndex=index,globalIndex=index,kvHeads=2 if full else 8,
            headDimension=512 if full else 256,window=0 if full else 1024,dtype=dtype),'Layer geometry/identity differs')
        rows.append(f"{index}|{index}|{layer['kvHeads']}|{layer['headDimension']}|{'full' if full else 1024}|{dtype}")
    require(value['stateLayoutSHA256']==text_hash(rows),'State layout fingerprint differs')

def finite(raw, dtype):
    if dtype=='bfloat16':
        require(all((bits&0x7f80)!=0x7f80 for (bits,) in struct.iter_unpack('<H',raw)),'Nonfinite BF16 state')
    else:
        require(all(math.isfinite(x) for (x,) in struct.iter_unpack('<e' if dtype=='float16' else '<f',raw)),
                'Nonfinite native state')

def request_hash(job, ordinal, prompt):
    profile=digest('|'.join(['qwen-stage-generation-profile-v1','registered_gemma4_26b_forward_validation_v1',
                            '262144','2816','bfloat16','8192','512','128','8320']).encode())
    tokens=digest(','.join(map(str,prompt)).encode())
    return text_hash(['qwen-stage-generation-request-v1',profile,job['requestIDs'][ordinal],
                      'prompt='+tokens,'chunk=64','output=16','stop='])

def ordinary_scope(job, plan, requests):
    return text_hash(['gemma4-resident-benchmark-v1',job['membershipEpoch'],job['buildIdentitySHA256'],plan,
        job['promptFileSHA256'],'cut=7','warmup=1','measure=3','mtp=false',
        'capture='+str(job['captureEvidence']).lower()]+requests+['prefill=serial'])

