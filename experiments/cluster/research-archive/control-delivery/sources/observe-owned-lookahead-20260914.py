#!/usr/bin/env python3
"""Read-only process observer; launched before the root-owned pair."""
import datetime,hashlib,json,subprocess,time
from pathlib import Path
ROOT=Path('/Users/developer/DarkbloomDev/cluster-research')
RUN=ROOT/'runs/qwen-layer-stage-lookahead-20260914'
OUT=ROOT/'qwen-layer-stage-lookahead-process-observations-20260914.json'
assert not OUT.exists()
start=time.monotonic();samples=[];native=str(RUN/'bundle/cluster-inference')
while time.monotonic()-start < 300:
    raw=subprocess.check_output(['/bin/ps','-axo','pid=,ppid=,rss=,command='],text=True,timeout=2)
    owned=[]
    for line in raw.splitlines():
        fields=line.split(None,3)
        if len(fields)!=4: continue
        pid,ppid,rss,command=fields
        is_native=command==native or command.startswith(native+' ')
        is_supervisor=('rank_worker.py ' in command and str(RUN)+'/rank-' in command)
        if is_native or is_supervisor:
            owned.append(dict(pid=int(pid),ppid=int(ppid),rssBytes=int(rss)*1024,native=is_native,supervisor=is_supervisor))
    samples.append(dict(monotonicSeconds=time.monotonic(),ownedProcesses=owned))
    receipt=RUN/'receipt.json'
    if receipt.exists():
        try: done='rank_files' in json.loads(receipt.read_text())
        except (json.JSONDecodeError,OSError): done=False
        if done: break
    time.sleep(.2)
native_seen=[p for sample in samples for p in sample['ownedProcesses'] if p['native']]
result=dict(kind='owned_lookahead_process_observations',schemaVersion=1,
    observedAtUTC=datetime.datetime.now(datetime.timezone.utc).isoformat(),
    observerSHA256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
    samples=samples,nativeRSSMeasurementAvailable=bool(native_seen),
    peakObservedSumNativeRSSBytes=max((sum(p['rssBytes'] for p in s['ownedProcesses'] if p['native']) for s in samples),default=0) if native_seen else None,
    observedNativePIDs=sorted({p['pid'] for p in native_seen}),
    terminatedOnLauncherFinalReceipt=receipt.exists() and done,
    limitation='Sampled RSS only; a combined sampled maximum can miss the actual peak. Read-only observer does not retire processes.')
with OUT.open('x') as out:json.dump(result,out,indent=2);out.write('\n')
print(json.dumps({k:v for k,v in result.items() if k!='samples'}))
