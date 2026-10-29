"""Closed lab jobs; no model/member/approval configuration is accepted."""
import hashlib
import json
import os
from pathlib import Path
import re
import uuid
from binding_common import require

REMOTE = Path('/Users/developer/DarkbloomDev/cluster-lab-encrypted-rdma-20260920')
PRODUCTS = ('LabAuthenticatedRDMABenchmark',)
PAYLOADS = (1,5632,8192,10240,65536,131072,360448,720896,1048576,4194304,5242880)
MODES = ('raw_payload','raw_record_size','encrypted_record','encrypted_array')

def write_json(path,value):
    raw=json.dumps(value,sort_keys=True,separators=(',',':'),allow_nan=False).encode()+b'\n'
    fd=os.open(path,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
    with os.fdopen(fd,'wb') as stream:stream.write(raw);stream.flush();os.fsync(stream.fileno())

def product(job): validate_job(job);return PRODUCTS[0]

def validate_native(n):
    keys={'schema','identityKind','runID','rank','payloadBytes','warmups','measurements','timeoutSeconds',
          'hostKeySHA256','nativeBuildSHA256','sourceSnapshotSHA256','mlxArtifactSHA256','secretCommitmentSHA256',
          'expectedHardware','expectedOSBuild'}
    require(type(n) is dict and set(n)==keys,'Lab native fields')
    require(n['schema']=='lab_authenticated_rdma_component_v1' and n['identityKind']=='ssh_host_key_lab_only', 'Lab identity kind')
    require(str(uuid.UUID(n['runID']))==n['runID'] and type(n['rank']) is int and n['rank'] in (0,1),'Lab run/rank')
    require(type(n['payloadBytes']) is int and n['payloadBytes'] in PAYLOADS and
            type(n['warmups']) is int and n['warmups']==3 and type(n['measurements']) is int and n['measurements']==20 and
            type(n['timeoutSeconds']) is int and n['timeoutSeconds']==120,'Lab workload')
    for key in ('hostKeySHA256','nativeBuildSHA256','expectedHardware','expectedOSBuild'):
        require(type(n[key]) is list and len(n[key])==2,'Lab two hosts')
    require(len(set(n['hostKeySHA256']))==2,'Lab distinct authenticated host keys')
    pins=n['hostKeySHA256']+n['nativeBuildSHA256']+[n['sourceSnapshotSHA256'],n['mlxArtifactSHA256'],n['secretCommitmentSHA256']]
    require(all(type(x) is str and re.fullmatch('[0-9a-f]{64}',x) and x!='0'*64 for x in pins),'Lab digest fields')
    require(all(type(x) is str and 1<=len(x.encode())<=128 and '\n' not in x for x in n['expectedHardware']+n['expectedOSBuild']),'Lab actual hardware/OS fields')

def validate_job(job):
    require(type(job) is dict and set(job)=={'schema','kind','mode','nativeSHA256','timeoutSeconds','nativeJob'},'Lab physical fields')
    require(job['schema']=='lab_record_physical_job_v1' and job['kind']=='rdma' and job['mode'] in ('stage0','stage1') and job['timeoutSeconds']==120,'Lab physical scope')
    n=job['nativeJob'];validate_native(n)
    rank=0 if job['mode']=='stage0' else 1
    require(n['rank']==rank and job['nativeSHA256']==n['nativeBuildSHA256'][rank],'Lab actual binary binding')

def arguments(job,job_path):
    validate_job(job);inner=job_path.parent/'native-job.json'
    expected=json.dumps(job['nativeJob'],sort_keys=True,separators=(',',':'),allow_nan=False).encode()+b'\n'
    require(not inner.is_symlink() and inner.stat().st_size==len(expected) and inner.read_bytes()==expected,'Lab exact native job changed')
    return ['--execute',str(inner)],hashlib.sha256(expected).hexdigest()

def scope(n):
    validate_native(n)
    fields=[n[k] for k in ('schema','identityKind','runID')]
    fields += [str(n[k]) for k in ('payloadBytes','warmups','measurements','timeoutSeconds')]
    fields += [n[k] for k in ('sourceSnapshotSHA256','mlxArtifactSHA256','secretCommitmentSHA256')]
    fields += n['hostKeySHA256']+n['nativeBuildSHA256']+n['expectedHardware']+n['expectedOSBuild']
    return hashlib.sha256('\n'.join(fields).encode()).hexdigest()
