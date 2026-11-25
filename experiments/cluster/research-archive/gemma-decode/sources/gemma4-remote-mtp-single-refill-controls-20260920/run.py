"""Root-scheduled Foundation controls, original bounded process-group owner."""
import argparse,hashlib,json,time
from pathlib import Path
from owned_process import invoke_controller
ROOT=Path(__file__).resolve().parent

def digest(path):return hashlib.sha256(Path(path).read_bytes()).hexdigest()
def pin(path):
 path=Path(path);return dict(path=str(path),bytes=path.stat().st_size,sha256=digest(path))
def require_pin(row):
 p=Path(row['path']);assert p.is_file() and not p.is_symlink() and p.stat().st_size<=2*1024**2
 assert pin(p)==row;return p

def check():
 own=json.loads((ROOT/'source-inputs.json').read_bytes())
 for row in own['members']:require_pin(dict(row,path=str(ROOT/row['path'])))
 inputs=json.loads((ROOT/'inputs.json').read_bytes())
 for key in ('sourceManifest','rebaseManifest','ownedHelperSourceManifest'):
  p=require_pin(inputs[key]);doc=json.loads(p.read_bytes())
  for row in doc['members']:require_pin(dict(row,path=str(p.parent/row['path'])))
 require_pin(inputs['ownedHelperPredecessor'])
 for row in inputs['swiftSources']:require_pin(row)
 assert len(inputs['expectedLabels'])==len(set(inputs['expectedLabels']))==11
 return inputs

def phase(out,name,argv,timeout):
 record=dict(argv=argv,timeoutSeconds=timeout);started=time.monotonic()
 try:
  with (out/(name+'.stdout')).open('xb') as stdout,(out/(name+'.stderr')).open('xb') as stderr:
   invoke_controller(argv,stdout,stderr,record,timeout=timeout)
  assert record['exitCode']==0 and record['reaped'] is True and record['groupAbsent'] is True
  record['status']='passed'
 except BaseException as error:record.update(status='failed',error=type(error).__name__+': '+str(error));raise
 finally:
  record['elapsedSeconds']=time.monotonic()-started
  for suffix in ('stdout','stderr'):
   p=out/(name+'.'+suffix)
   if p.exists():record[suffix]=pin(p)
  with (out/(name+'.json')).open('x') as f:json.dump(record,f,indent=2);f.write('\n')
 return record

def main():
 p=argparse.ArgumentParser(allow_abbrev=False);g=p.add_mutually_exclusive_group(required=True)
 g.add_argument('--check',action='store_true');g.add_argument('--run',action='store_true');a=p.parse_args()
 inputs=check()
 if a.check:print(json.dumps(dict(sourceOnly=True,stagedGroups=11,compilerExecuted=False)));return
 out=ROOT/'qualification-1';out.mkdir(mode=0o700);binary=out/'RefillPolicyChecks'
 receipt=dict(schema='gemma4_single_refill_foundation_qualification_v1',sourceManifest=pin(ROOT/'source-inputs.json'),inputs=inputs,nativeInferenceExecuted=False,gpuExecuted=False)
 try:
  receipt['compile']=phase(out,'compile',['/usr/bin/xcrun','swiftc','-swift-version','6','-warnings-as-errors','-j','2','-module-cache-path',str(out/'module-cache'),*[x['path'] for x in inputs['swiftSources']],'-o',str(binary)],60)
  receipt['run']=phase(out,'run',[str(binary)],10)
  assert (out/'run.stderr').stat().st_size==0 and (out/'run.stdout').stat().st_size<16384
  result=json.loads((out/'run.stdout').read_bytes())
  assert set(result)=={'schema','passed','nativeExecuted'} and result['schema']=='gemma4_remote_mtp_refill_policy_checks_v1'
  assert result['passed']==inputs['expectedLabels'] and result['nativeExecuted'] is False
  assert check()==inputs
  receipt.update(status='passed',passed=result['passed'],binary=pin(binary))
 except BaseException as error:receipt.update(status='failed',error=type(error).__name__+': '+str(error));raise
 finally:
  with (out/'receipt.json').open('x') as f:json.dump(receipt,f,indent=2);f.write('\n')
  print(json.dumps(receipt),flush=True)
if __name__=='__main__':main()
