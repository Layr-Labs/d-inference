"""Exact role-bound P128/P4096 C64 O16/depth2 jobs with fresh request IDs."""
from pathlib import Path
import hashlib,json,re,uuid
from activation import recheck
from deploy import REMOTE,digest
ROOT=Path(__file__).resolve().parent
ROLES=[('assistant','darkbloom-24'),('target','darkbloom-48')]
def encode(value):return (json.dumps(value,sort_keys=True,separators=(',',':'),allow_nan=False)+'\n').encode()
def hash_bytes(value):return hashlib.sha256(value).hexdigest()
def prepare(name,count,capture,embedding):
    assert count in [128,4096] and type(capture) is bool and re.fullmatch('[0-9a-f]{64}',embedding)
    activation=recheck();directory=ROOT/'cases'/name;directory.mkdir(mode=0o700,parents=True)
    requests=[str(uuid.uuid4()) for _ in range(4)];epoch=str(uuid.uuid4())
    for role,_ in ROLES:
        folder=directory/role;folder.mkdir(mode=0o700);remote=REMOTE+'/runs/'+name+'-'+role
        job=dict(schema='gemma4_resident_benchmark_v1',mode='full',modelDirectory='/Users/developer/DarkbloomDev/models/Gemma4-26B',
            metadataDirectory=REMOTE+'/metadata',promptFile=REMOTE+f'/prompts/prompt-{count}.json',
            promptFileSHA256=digest(ROOT/'prompts'/f'prompt-{count}.json'),requestIDs=requests,membershipEpoch=epoch,
            buildIdentitySHA256=activation['nativeSHA256'],residualDType='bfloat16',promptCount=count,chunkSize=64,outputCount=16,
            timeoutSeconds=300,captureEvidence=False,cut=7,prefillPolicy='serial',outputDirectory=remote+'/sidecars')
        local=dict(schema='gemma4_local_mtp_cohort_job_v1',benchmarkJob=remote+'/job.json',benchmarkJobSHA256=hash_bytes(encode(job)),
            assistantModelDirectory='/Users/developer/DarkbloomDev/models/Gemma4-26B-assistant-bb94eae1',assistantMetadataDirectory=REMOTE+'/assistant-metadata',
            maximumDraftTokens=2,captureEvidence=capture)
        wrapper=dict(schema='gemma4_remote_mtp_cohort_job_v1',role=role,localMTPJob=remote+'/local-mtp.json',localMTPJobSHA256=hash_bytes(encode(local)),
            targetNativeSHA256=activation['nativeSHA256'],assistantNativeSHA256=activation['nativeSHA256'],embeddingIdentitySHA256=embedding)
        for filename,value in [('job.json',job),('local-mtp.json',local),('remote-mtp.json',wrapper)]:
            with (folder/filename).open('xb') as f:f.write(encode(value))
    print(json.dumps(dict(status='prepared',case=name,promptCount=count,depth=2,capture=capture,embeddingIdentitySHA256=embedding)))
