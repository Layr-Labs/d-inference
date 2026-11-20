"""One installed-native metadata call; no inference or model-weight execution."""
import argparse
import hashlib
import json
from pathlib import Path
import shlex
import subprocess

from deploy import REMOTE, digest
from parent_settings import SSH

ROOT = Path(__file__).resolve().parent

REMOTE_BODY = r'''
import hashlib,json,os,pathlib,stat,sys,time
root=pathlib.Path(sys.argv[1]);package_sha,job_sha,name,operation=sys.argv[2:]
assert str(root)=='/Users/developer/DarkbloomDev/gemma4-local-mtp-profile-20260920'
assert operation in ('--describe','--check-arguments')
assert name and all(c.isalnum() or c in '-_' for c in name)
sys.path.insert(0,str(root))
from benchmark_package import verify,digest
from mtp_journal import device_directory,observe,require_empty
from target_processes import observe as processes
verify(package_sha)
require_empty(observe(device_directory()))
assert not processes(time.monotonic()+4)['prohibited']
raw=sys.stdin.buffer.read(131073);assert len(raw)<=131072 and hashlib.sha256(raw).hexdigest()==job_sha
job=json.loads(raw);binary=root/'bundle/GemmaResidentBenchmark'
assert job['buildIdentitySHA256']==digest(binary)
assert job['schema']=='gemma4_resident_benchmark_v1'
assert job['metadataDirectory']==str(root/'metadata')
assert job['modelDirectory']=='/Users/developer/DarkbloomDev/models/Gemma4-26B'
assert not pathlib.Path(job['outputDirectory']).exists()
os.umask(0o077);parent=root/'metadata-checks';parent.mkdir(mode=0o700,exist_ok=True)
assert parent.resolve()==parent and not parent.is_symlink()
output=parent/name;output.mkdir(mode=0o700)
path=output/'job.json'
with path.open('xb') as stream:stream.write(raw)
receipt={'schema':'gemma4_decode_metadata_child_v1','argv':[str(binary),operation,str(path)],'nativeSHA256':job['buildIdentitySHA256'],'jobSHA256':job_sha,'packageSHA256':package_sha,'metadataOnly':True,'gpuExecuted':False}
started=time.monotonic()
try:
 with (output/'stdout').open('xb') as stdout,(output/'stderr').open('xb') as stderr:
  invoke_controller(receipt['argv'],stdout,stderr,receipt,timeout=15)
 assert receipt['exitCode']==0 and receipt['reaped'] and receipt['groupAbsent']
 assert (output/'stderr').stat().st_size==0 and (output/'stdout').stat().st_size<=1048576
 result=json.loads((output/'stdout').read_bytes())
 assert result['metadataOnly'] is True and result['runtimeExecutionAuthorized'] is False
 assert result['job']==job and not pathlib.Path(job['outputDirectory']).exists()
 verify(package_sha);require_empty(observe(device_directory()))
 assert not processes(time.monotonic()+4)['prohibited']
 receipt['status']='passed';receipt['description']=result
except BaseException as error:
 receipt['status']='failed';receipt['error']=type(error).__name__+': '+str(error)
 raise
finally:
 receipt['elapsedSeconds']=time.monotonic()-started
 for name in ('stdout','stderr'):
  p=output/name
  if p.exists():receipt[name+'SHA256']=digest(p);receipt[name+'Bytes']=p.stat().st_size
 with (output/'receipt.json').open('x') as stream:json.dump(receipt,stream,indent=2)
print(json.dumps(receipt,sort_keys=True),flush=True)
'''

def main():
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument('--case', required=True)
    parser.add_argument('--mode', choices=['full'], required=True)
    parser.add_argument('--operation', choices=['describe', 'check-arguments'], default='describe')
    args = parser.parse_args()
    assert args.case and all(c.isalnum() or c in '-_' for c in args.case)
    host = 'darkbloom-24' if args.mode == 'stage0' else 'darkbloom-48'
    raw = (ROOT / 'cases' / args.case / (args.mode + '.json')).read_bytes()
    package_sha = digest(ROOT / 'deployment/package.json')
    name = args.case + '-' + args.mode + '-' + args.operation
    script = (ROOT / 'owned_process.py').read_text() + '\n' + REMOTE_BODY
    command = SSH + [host, shlex.join(['/usr/bin/python3', '-B', '-c', script,
        REMOTE, package_sha, hashlib.sha256(raw).hexdigest(), name, '--' + args.operation])]
    # The enclosing root runner owns/reaps this SSH process group and retains
    # regular stdout/stderr files. The remote native child has its own 15s owner.
    process = subprocess.run(command, input=raw, timeout=40)
    raise SystemExit(process.returncode)

if __name__ == '__main__':
    main()
