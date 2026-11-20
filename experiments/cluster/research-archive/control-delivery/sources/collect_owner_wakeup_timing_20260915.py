from pathlib import Path
import base64,hashlib,json,shlex,subprocess,sys
R=Path('/Users/developer/DarkbloomDev/cluster-research')
mode=sys.argv[1];assert mode in ['serial','lookahead']
B=R/f'owner-timing-{mode}-wakeup-20260915';O=B/'physical-1'
run=json.loads((O/'execution.json').read_text());assert run['runCompletedAndAliasRestored']
records=[json.loads(s) for s in (O/'controller.stdout.jsonl').read_text().splitlines()]
result=records[-1];assert result['schema']=='owner_timing_cohort_result_v1' and result['completed']
assert result['nativeCleanupObserved']==[True,True] and result['ownerDeviceLeaseReleasedObserved']==[True,True]
requests=result['requests'];assert len(requests)==4 and all(x['completed'] and x['sequenceGuardMatched'] for x in requests)
ids=[x['requestID'] for x in requests];assert len(set(ids))==4
code=r'''
from pathlib import Path
import base64,hashlib,json,subprocess,sys
base=Path(sys.argv[1]); records=[]
for f in sorted((base/'evidence').glob('*.json')):
 assert f.is_file() and not f.is_symlink() and f.stat().st_size<=3000000
 b=f.read_bytes();records.append({'name':f.name,'bytes':len(b),'sha256':hashlib.sha256(b).hexdigest(),'data':base64.b64encode(b).decode()})
assert len(records)<=4
journals=[{'name':p.name,'bytes':p.stat().st_size} for p in (base/'lease').iterdir() if p.is_file()]
ps=subprocess.check_output(['/bin/ps','-axo','pid=,comm='],text=True)
processes=[s.strip() for s in ps.splitlines() if Path(s.split(maxsplit=1)[1]).name in ['darkbloom-cluster-worker','darkbloom-owner-qualification']]
print(json.dumps({'evidence':records,'leaseFiles':journals,'processes':processes,'en1':subprocess.check_output(['/sbin/ifconfig','en1'],text=True),'swap':subprocess.check_output(['/usr/sbin/sysctl','vm.swapusage'],text=True)}))
'''
for rank,host in enumerate(['darkbloom-24','darkbloom-48']):
 out=O/f'postflight-{rank}.json';assert not out.exists()
 x=subprocess.run(['ssh','-T','-o','BatchMode=yes','-o','ConnectTimeout=5',host,shlex.join(['/usr/bin/python3','-c',code,f'/Users/developer/DarkbloomDev/{B.name}'])],capture_output=True,text=True,check=True,timeout=20)
 rec=json.loads(x.stdout);assert not rec['processes'];assert all(f['bytes']==0 for f in rec['leaseFiles'])
 assert {f['name'] for f in rec['evidence']}=={u+'.json' for u in ids}
 dest=O/f'evidence-rank{rank}';dest.mkdir(mode=0o700)
 for f in rec['evidence']:
  b=base64.b64decode(f.pop('data'),validate=True);assert hashlib.sha256(b).hexdigest()==f['sha256'];(dest/f['name']).write_bytes(b)
 out.write_text(json.dumps(rec,indent=2)+'\n')
print(json.dumps({'mode':mode,'bothCleanupAndLeaseACK':True,'bothPostflightJournalsZero':True,'noOwnerOrWorkerProcesses':True,'sidecars':8,'summary':result['summary']}))
