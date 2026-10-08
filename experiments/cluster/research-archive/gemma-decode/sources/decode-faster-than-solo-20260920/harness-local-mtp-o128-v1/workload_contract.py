"""Closed full-model cohort counts; no resource or execution authority."""
def require(condition, message):
    if not condition: raise ValueError(message)

def counts(job):
    require(type(job) is dict and job.get('schema')=='gemma4_resident_benchmark_v1'
        and job.get('mode')=='full' and type(job.get('promptCount')) is int and job['promptCount'] in (128,4096)
        and type(job.get('outputCount')) is int and job['outputCount'] in (16,128)
        and type(job.get('chunkSize')) is int and job['chunkSize']==64
        and type(job.get('cut')) is int and job['cut']==7
        and job.get('residualDType')=='bfloat16' and job.get('prefillPolicy')=='serial'
        and type(job.get('timeoutSeconds')) is int and job['timeoutSeconds']==300,
        'Closed full P128/P4096 C64 O16/O128 cut7 BF16 workload')
    p,o=job['promptCount'],job['outputCount']
    return dict(prompt=p,output=o,decode=o-1,frontier=p+o-1,maximumTokens=p+o,
        measuredDecodeTokens=3*(o-1),allGeneratedTokens=4*o,frames=(p+63)//64+o-1)

def state_geometry(layer,component,frontier):
    require(type(frontier) is int and 1<=frontier<=4223,'Closed final frontier')
    if component=='kv.position_offsets':return 'int32',[1],4,[]
    require(component in ('kv.keys','kv.values'),'Canonical attention component')
    dtype=layer['dtype'];require(dtype in ('float16','bfloat16','float32'),'Observed cache dtype')
    start=max(0,frontier-layer['window']) if layer['window'] else 0
    shape=[1,layer['kvHeads'],frontier-start,layer['headDimension']]
    count=shape[1]*shape[2]*shape[3]*(4 if dtype=='float32' else 2)
    return dtype,shape,count,[start,frontier]

def target_extra_logical_bytes(job):
    f=counts(job)['frontier']
    # Exact34-term identity sum: two width4 outputs, four1MiB headrows,
    # one snapshot, separately named sender packs, hidden and16KiB control.
    return 40053794+8192*f+16384*min(f,1024)
