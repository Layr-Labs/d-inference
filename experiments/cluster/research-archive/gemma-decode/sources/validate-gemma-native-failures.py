"""Actual tiny native workers: epoch cancellation and peer-command disagreement."""
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time
import shutil

REPO=Path('/Users/developer/DarkbloomDev/d-inference')
CLUSTER=REPO/'experiments/cluster'
sys.path.insert(0,str(CLUSTER))
from runtime.persistent import PersistentCohort, PersistentCohortError
from runtime.configuration import loopback_addresses

BUNDLE=CLUSTER/'inference/.build/arm64-apple-macosx/release'
OUT=Path(sys.argv[1]);OUT.mkdir(mode=0o700,parents=True,exist_ok=False)
receipt=dict(binary_sha256=hashlib.sha256((BUNDLE/'cluster-inference').read_bytes()).hexdigest(),
    driver_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),synthetic_only=True,
    performance_qualification=False,cancellation=[])
sources=[]
for name in sorted(subprocess.check_output(['rg','--files','experiments/cluster'],cwd=REPO,text=True).splitlines()):
    path=REPO/name; target=OUT/'source'/path.relative_to(CLUSTER)
    target.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(path,target)
    sources.append(dict(path=name,sha256=hashlib.sha256(target.read_bytes()).hexdigest()))
manifest=OUT/'source-manifest.json';manifest.write_text(json.dumps(sources,indent=2)+'\n')
receipt['source_manifest_sha256']=hashlib.sha256(manifest.read_bytes()).hexdigest()
shutil.copyfile(Path(__file__),OUT/Path(__file__).name)

for distributed in (False,True):
    spec=dict(schema_version=1,backend='loopback-test' if distributed else 'solo',
        partition='ffn',ranks=[dict(location='local')]*(2 if distributed else 1),
        workload=dict(synthetic=True,synthetic_profile='gemma-moe'),timeout_seconds=30)
    cohort=PersistentCohort(spec,BUNDLE,OUT/('ffn' if distributed else 'solo'))
    try:
        cohort.start();pids=cohort.workerPIDs;delivered=[]
        start=time.monotonic()
        def cancel_after_first(step,token):
            delivered.append([step,token]);cohort.cancel()
        try:
            cohort.infer('cancel',[3+(i*17+7)%509 for i in range(65)],4096,32,
                         timeout_seconds=15,on_token=cancel_after_first)
            raise AssertionError('Cancelled inference returned success')
        except PersistentCohortError:pass
        elapsed=time.monotonic()-start
        assert cohort.epoch is None and cohort.state=='failed' and len(delivered)==1
        for pid in pids:
            try:os.kill(pid,0)
            except ProcessLookupError:pass
            else:raise AssertionError(f'Native worker {pid} survived cancellation')
        try:cohort.infer('reuse',[3],1,1)
        except PersistentCohortError:pass
        else:raise AssertionError('Retired epoch reused')
        receipt['cancellation'].append(dict(distributed=distributed,seconds=elapsed,
            worker_pids=pids,delivered=delivered,all_native_workers_reaped=True,epoch_reuse_rejected=True))
        print('cancel','ffn' if distributed else 'solo',round(elapsed,3),'seconds; no native workers remain',flush=True)
    finally:cohort.close()

# Deliberately bypass the controller to prove the native collective rejects
# mismatched semantic commands before either rank emits accepted or any token.
hosts=OUT/'hosts.json';hosts.write_text(json.dumps(loopback_addresses()))
epoch='c'*32
processes=[]
try:
    for rank in range(2):
        env={k:v for k,v in os.environ.items() if not k.startswith(('MLX_','JACCL_','DARKBLOOM_'))}
        env.update(MLX_RANK=str(rank),MLX_HOSTFILE=str(hosts))
        processes.append(subprocess.Popen([str(BUNDLE/'cluster-inference'),'--mode','worker-tp',
            '--synthetic','--synthetic-profile','gemma-moe','--transport','loopback-test','--partition','ffn','--epoch',epoch,
            '--timeout-seconds','15'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,
            text=True,env=env,start_new_session=True))
    ready=[json.loads(p.stdout.readline()) for p in processes]
    assert all(r['type']=='ready' for r in ready)
    assert ready[0]['identity']==ready[1]['identity']
    for rank,p in enumerate(processes):
        request=dict(version=2,type='infer',epoch=epoch,sequence=1,requestID='mismatch',
            prompt=[3,7+rank,11],outputTokens=2,chunkSize=2,timeoutSeconds=5,captureLogits=False)
        p.stdin.write(json.dumps(request)+'\n');p.stdin.flush()
    records=[]
    for rank,p in enumerate(processes):
        out,err=p.communicate(timeout=10)
        (OUT/f'mismatch-rank-{rank}.stderr').write_text(err)
        (OUT/f'mismatch-rank-{rank}.stdout').write_text(out)
        assert p.returncode==1 and not out.strip() and 'Ranks disagree' in err
        records.append(dict(rank=rank,exit_code=p.returncode,no_accepted_or_token=True))
    receipt['native_mismatch']=records
    print('native peer command mismatch rejected by both ranks before accepted',flush=True)
finally:
    for p in processes:
        if p.poll() is None:
            os.killpg(p.pid,signal.SIGKILL);p.wait()
(OUT/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
