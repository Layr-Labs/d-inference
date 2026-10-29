from pathlib import Path
import base64, hashlib, json, shlex, subprocess, sys

ROOT = Path('/Users/developer/DarkbloomDev/cluster-research')
case = sys.argv[1]
assert case in ['before-first', 'after-decode']
base = ROOT / ('owner-cancellation-' + case + '-20260915')
output = base / 'physical-1'
run = json.loads((output / 'execution.json').read_text())
records = [json.loads(line) for line in (output / 'controller.stdout.jsonl').read_text().splitlines()]
result = next((r for r in reversed(records) if r.get('schema') == 'owner_cancellation_recovery_result_v1'), {})
requests = result.get('requests', [])
request_ids = {r['requestID'] for r in requests}
remote_code = r'''
from pathlib import Path
import base64,hashlib,json,subprocess,sys
base=Path(sys.argv[1]);records=[]
for f in sorted((base/'evidence').glob('*.json')):
 assert f.is_file() and not f.is_symlink() and f.stat().st_size<=3000000
 b=f.read_bytes();records.append({'name':f.name,'bytes':len(b),'sha256':hashlib.sha256(b).hexdigest(),'data':base64.b64encode(b).decode()})
assert len(records)<=2
journals=[{'name':p.name,'bytes':p.stat().st_size} for p in (base/'lease').iterdir() if p.is_file()]
ps=subprocess.check_output(['/bin/ps','-axo','pid=,comm='],text=True)
processes=[s.strip() for s in ps.splitlines() if Path(s.split(maxsplit=1)[1]).name in ['darkbloom-cluster-worker','darkbloom-owner-qualification']]
print(json.dumps({'evidence':records,'leaseFiles':journals,'processes':processes,'en1':subprocess.check_output(['/sbin/ifconfig','en1'],text=True),'swap':subprocess.check_output(['/usr/sbin/sysctl','vm.swapusage'],text=True)}))
'''
postflights = []
for rank, host in enumerate(['darkbloom-24', 'darkbloom-48']):
    destination = output / f'postflight-{rank}.json'
    assert not destination.exists()
    command = ['ssh', '-T', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=5', host,
               shlex.join(['/usr/bin/python3', '-c', remote_code, '/Users/developer/DarkbloomDev/' + base.name])]
    child = subprocess.run(command, capture_output=True, text=True, timeout=20)
    if child.returncode:
        record = {'observationFailed': True, 'exitCode': child.returncode, 'stdout': child.stdout, 'stderr': child.stderr}
    else:
        record = json.loads(child.stdout)
        evidence_dir = output / f'evidence-rank{rank}'
        evidence_dir.mkdir(mode=0o700)
        for item in record['evidence']:
            data = base64.b64decode(item.pop('data'), validate=True)
            assert hashlib.sha256(data).hexdigest() == item['sha256'] and len(data) == item['bytes']
            assert Path(item['name']).name == item['name']
            (evidence_dir / item['name']).write_bytes(data)
    destination.write_text(json.dumps(record, indent=2) + '\n')
    postflights.append(record)
summary = {'case': case, 'controllerCompleted': result.get('completed', False),
           'wrapperCompletedAndAliasRestored': run.get('runCompletedAndAliasRestored', False),
           'nativeCleanupObserved': result.get('nativeCleanupObserved'),
           'ownerDeviceLeaseReleasedObserved': result.get('ownerDeviceLeaseReleasedObserved'),
           'postflightObserved': all(not p.get('observationFailed') for p in postflights),
           'noOwnerOrWorkerProcesses': all(p.get('processes') == [] for p in postflights),
           'bothPostflightJournalsZero': all(p.get('leaseFiles') and all(f['bytes'] == 0 for f in p['leaseFiles']) for p in postflights),
           'sidecarRequestIDsJoined': all(all(f['name'][:-5] in request_ids for f in p.get('evidence', [])) for p in postflights)}
(output / 'collection.json').write_text(json.dumps(summary, indent=2) + '\n')
print(json.dumps(summary))
raise SystemExit(0 if all(summary[k] for k in ['controllerCompleted','wrapperCompletedAndAliasRestored',
                  'postflightObserved','noOwnerOrWorkerProcesses','bothPostflightJournalsZero','sidecarRequestIDsJoined']) else 1)
