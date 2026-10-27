"""Create three pinned input files and run metadata-only description on both roles."""
from pathlib import Path
import argparse,json,shlex,subprocess
from deploy import REMOTE,digest
from jobs import ROLES,encode,hash_bytes
from parent_settings import SSH
ROOT=Path(__file__).resolve().parent
BODY=r'''
import hashlib,json,os,pathlib,sys,time
root=pathlib.Path(sys.argv[1]);package_sha,name,role,payload_sha=sys.argv[2:]
assert str(root)=='/Users/developer/DarkbloomDev/gemma4-remote-mtp-qualification-20260920-v2'
assert role in ('target','assistant') and name and all(c.isalnum() or c in '-_' for c in name)
sys.path.insert(0,str(root))
from benchmark_package import verify,digest
from mtp_journal import device_directory,observe,require_empty
from target_processes import observe as processes
from remote_mtp_contract import validate_inputs
verify(package_sha);require_empty(observe(device_directory()));assert not processes(time.monotonic()+4)['prohibited']
raw=sys.stdin.buffer.read(65537);assert len(raw)<=65536 and hashlib.sha256(raw).hexdigest()==payload_sha
payload=json.loads(raw);assert set(payload)=={'job.json','local-mtp.json','remote-mtp.json'}
job,local,wrapper=[payload[x] for x in ('job.json','local-mtp.json','remote-mtp.json')]
encode=lambda v:(json.dumps(v,sort_keys=True,separators=(',',':'),allow_nan=False)+'\n').encode()
run=root/'runs'/(name+'-'+role);job_sha=hashlib.sha256(encode(job)).hexdigest();local_sha=hashlib.sha256(encode(local)).hexdigest()
assert validate_inputs(job,local,wrapper,job_sha,local_sha,run)==role
assert job['buildIdentitySHA256']==digest(root/'bundle/GemmaResidentBenchmark')
assert not pathlib.Path(job['outputDirectory']).exists()
os.umask(0o077);run.parent.mkdir(mode=0o700,exist_ok=True);run.mkdir(mode=0o700)
for filename,value in payload.items():
 with (run/filename).open('xb') as f:f.write(encode(value))
output=run/'metadata';output.mkdir(mode=0o700)
receipt=dict(schema='gemma4_remote_mtp_metadata_v1',role=role,packageSHA256=package_sha,jobSHA256=job_sha,localMTPConfigSHA256=local_sha,
 remoteMTPConfigSHA256=digest(run/'remote-mtp.json'),nativeSHA256=job['buildIdentitySHA256'],metadataOnly=True,gpuExecuted=False)
receipt['argv']=[str(root/'bundle/GemmaResidentBenchmark'),'--describe-remote-mtp',str(run/'remote-mtp.json')]
started=time.monotonic()
try:
 with (output/'stdout').open('xb') as out,(output/'stderr').open('xb') as err:invoke_controller(receipt['argv'],out,err,receipt,timeout=20)
 assert receipt['exitCode']==0 and receipt['reaped'] and receipt['groupAbsent']
 assert (output/'stderr').stat().st_size==0 and (output/'stdout').stat().st_size<=1048576
 value=json.loads((output/'stdout').read_bytes())
 assert value['schema']=='gemma4_remote_mtp_cohort_capability_v1' and value['job']==wrapper and value['role']==role
 assert value['rank']==(1 if role=='target' else 0) and value['metadataOnly'] is True
 assert value['runtimeExecutionAuthorized'] is False and value['servingEnabled'] is False and value['maximumDraftTokens']==2 and value['maximumBufferedProposals']==5
 assert not pathlib.Path(job['outputDirectory']).exists()
 verify(package_sha);require_empty(observe(device_directory()));assert not processes(time.monotonic()+4)['prohibited']
 receipt.update(status='passed',description=value)
except BaseException as e:receipt.update(status='failed',error=type(e).__name__+': '+str(e));raise
finally:
 receipt['elapsedSeconds']=time.monotonic()-started
 for name in ['stdout','stderr']:
  f=output/name
  if f.exists():receipt[name+'SHA256']=digest(f);receipt[name+'Bytes']=f.stat().st_size
 with (output/'receipt.json').open('x') as f:json.dump(receipt,f,indent=2)
print(json.dumps(receipt,sort_keys=True),flush=True)
'''
def main():
    p=argparse.ArgumentParser(allow_abbrev=False);p.add_argument('--case',required=True);a=p.parse_args()
    assert a.case and all(c.isalnum() or c in '-_' for c in a.case)
    script=(ROOT/'owned_process.py').read_text()+'\n'+BODY
    for role,host in ROLES:
        payload={n:json.loads((ROOT/'cases'/a.case/role/n).read_bytes()) for n in ['job.json','local-mtp.json','remote-mtp.json']};raw=encode(payload)
        command=SSH+[host,shlex.join(['/usr/bin/python3','-B','-c',script,REMOTE,digest(ROOT/'deployment/package.json'),a.case,role,hash_bytes(raw)])]
        result=subprocess.run(command,input=raw,timeout=45)
        assert result.returncode==0,role
if __name__=='__main__':main()
