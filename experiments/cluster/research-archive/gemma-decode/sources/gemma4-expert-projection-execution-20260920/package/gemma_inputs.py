"""Closed expert physical jobs; no execution or model loading in validation."""
import hashlib
import json
import os
import re
from pathlib import Path
from binding_common import require

REMOTE=Path('/Users/developer/DarkbloomDev/gemma4-expert-projection-execution-20260920')
PRODUCTS=('GemmaExpertAxisCheck','GemmaExpertRDMACheck')
MODEL='/Users/developer/DarkbloomDev/models/Gemma4-26B'

def write_json(path,value):
    raw=json.dumps(value,sort_keys=True,separators=(',',':'),allow_nan=False).encode()+b'\n'
    fd=os.open(path,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
    with os.fdopen(fd,'wb') as stream:stream.write(raw);stream.flush();os.fsync(stream.fileno())

def product(job):return PRODUCTS[1] if job['kind']=='rdma' else PRODUCTS[0]

def validate_job(job):
    require(type(job) is dict and set(job)=={'schema','kind','mode','layer','modelDirectory','nativeSHA256','timeoutSeconds','nativeJob'},'Expert physical job fields')
    require(job['schema']=='gemma4_expert_physical_job_v1' and job['kind'] in ('synthetic-small','synthetic-gemma','checkpoint','rdma'),'Expert job schema/kind')
    require(type(job['layer']) is int and 0<=job['layer']<30 and job['modelDirectory']==MODEL,'Expert source/layer')
    require(job['timeoutSeconds']==300 and re.fullmatch('[0-9a-f]{64}',job['nativeSHA256']) is not None,'Expert native identity/lifetime')
    if job['kind']!='rdma':
        require(job['mode']=='full' and job['nativeJob'] is None,'Primitive role/inner job')
        return
    n=job['nativeJob']
    require(job['mode'] in ('stage0','stage1') and type(n) is dict,'RDMA role/inner job')
    require(set(n)=={'schema','modelDirectory','membershipEpoch','requestID','buildIdentitySHA256','ownership','rank','layer','tokenCounts','timeoutSeconds'},'RDMA inner fields')
    require(n['schema']=='gemma4_expert_rdma_check_v1' and n['modelDirectory']==MODEL and n['layer']==job['layer']
            and n['rank']==(0 if job['mode']=='stage0' else 1) and n['buildIdentitySHA256']==job['nativeSHA256']
            and n['timeoutSeconds']==300 and n['ownership'] in ('contiguous48_80','strided43_85'),'RDMA original bindings')
    for field in ('membershipEpoch','requestID'):
        import uuid
        require(type(n[field]) is str and str(uuid.UUID(n[field]))==n[field],'RDMA canonical UUID')
    counts=n['tokenCounts']
    require(type(counts) is list and 1<=len(counts)<=5 and all(type(x) is int and x in (1,7,8,9,33) for x in counts)
            and counts==sorted(set(counts)),'RDMA closed counts')

def arguments(job,job_path):
    validate_job(job)
    if job['kind'].startswith('synthetic-'):return ['--'+job['kind']],None
    if job['kind']=='checkpoint':return ['--checkpoint',MODEL,'--layer',str(job['layer'])],None
    inner=job_path.parent/'native-job.json'
    expected=json.dumps(job['nativeJob'],sort_keys=True,separators=(',',':'),allow_nan=False).encode()+b'\n'
    require(not inner.is_symlink() and inner.stat().st_size==len(expected) and inner.read_bytes()==expected,'Exact RDMA native job changed')
    return ['--execute',str(inner)],hashlib.sha256(expected).hexdigest()
