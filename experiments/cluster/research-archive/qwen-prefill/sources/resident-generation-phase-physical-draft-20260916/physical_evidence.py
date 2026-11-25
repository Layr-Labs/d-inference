"""Closed external ownership/reservation proof, separate from local phase arithmetic."""
from pathlib import Path
from decimal import Decimal
import base64,hashlib,json,re,stat,os
EMPTY=hashlib.sha256(b'').hexdigest()
def require(v,message):
    if not v:raise ValueError(message)
def digest(b):return hashlib.sha256(b).hexdigest()
def parse(raw):
    def unique(pairs):
        out={}
        for k,v in pairs:
            require(k not in out,'Duplicate JSON field');out[k]=v
        return out
    return json.loads(raw,object_pairs_hook=unique,parse_constant=lambda _:(_ for _ in ()).throw(ValueError('Nonfinite JSON')))
def read(p,limit=1024*1024):
    p=Path(p);fd=os.open(p,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK)
    try:
        s=os.fstat(fd);require(stat.S_ISREG(s.st_mode) and 0<=s.st_size<=limit,'Bounded regular input required')
        with os.fdopen(fd,'rb',closefd=False) as f:raw=f.read(limit+1)
        t=os.fstat(fd)
        require((s.st_dev,s.st_ino,s.st_size,s.st_mtime_ns,s.st_ctime_ns)==(t.st_dev,t.st_ino,t.st_size,t.st_mtime_ns,t.st_ctime_ns) and len(raw)==s.st_size,'Input changed')
        return raw
    finally:os.close(fd)
def pin(p):
    raw=read(p,16*1024*1024);return dict(path=str(p),bytes=len(raw),sha256=digest(raw))
def case_bound(case):
    here=Path(__file__).resolve().parent;case=Path(case).resolve()
    require(case.parent==here and case.name in ['serial','lookahead'],'Expected exact bound case')
    rows=parse(read(here/'bound-runs.json'))['runs'];row=next(x for x in rows if x['path']==str(case))
    raw=read(case/'manifest.json');require(digest(raw)==row['manifestSHA256'],'Case manifest changed')
    for n,x in parse(raw)['files'].items():
        p=case/n;r=read(p);require(len(r)==x['bytes'] and digest(r)==x['sha256'],'Bound case source changed')
    binding=parse(read(case/'binding.json'));require(binding['policy']==row['policy'],'Case policy differs')
    control=binding['nativeArgumentControls'];require(pin(Path(control['path']))==control and parse(read(control['path']))['passed'] is True,'Pure native argument proof changed')
    return case,binding

def terminal(case):
    case,binding=case_bound(case);physical=case/'physical-1'
    e=parse(read(physical/'execution.json'))
    for key in ['runCompletedAndAliasRestored','nativeProcessesAbsent','journalsEmpty','pinsUnchanged']:require(e.get(key) is True,'Incomplete physical parent: '+key)
    require(e['controllerExitCode']==0 and e['leaseExitCode']==0 and not any(k in e for k in ['error','remoteCleanupError','cleanupUnconfirmed']),'Physical failure')
    require(e['localController']['exitCode']==0 and e['localController']['reaped'] is True and e['localController']['groupAbsent'] is True and e['localController']['killedOwnedGroup'] is False,'Controller not naturally retired')
    require(len(e['leaseFinal'])==1 and e['leaseFinal'][0]['restored'] is True,'Alias not restored')
    require(len(e['monitors'])==2 and all(x==dict(exitCode=0,errors=[]) for x in e['monitors']),'Resource monitor failed')
    require(not e['remoteCleanup']['observationErrors'] and not e['remoteCleanup']['ownershipWindowExpired'],'Postflight incomplete')
    for row in e['outputFiles']:
        require(Path(row['path']).name==row['path'],'Unsafe output member');p=physical/row['path'];raw=read(p,16*1024*1024)
        require(len(raw)==row['bytes'] and digest(raw)==row['sha256'],'Physical output pin changed')
    raw=read(physical/'controller.stdout.jsonl',1024*1024);lines=raw.splitlines();require(len(lines)==2,'Expected started/final controller records')
    start,result=map(parse,lines);cfg=parse(read(case/'configuration/controller.json'));cfgsha=digest(read(case/'configuration/controller.json'))
    require(start['schema']=='owner_qualification_started_v1' and result['schema']=='owner_qualification_result_v1','Wrong controller schema')
    for item in [start,result]:require(item['configurationSHA256']==cfgsha and item['cpuQualification'] is False,'Controller configuration not bound')
    require(start['membershipEpoch']==binding['membershipEpoch'] and start['requestID']==binding['requestID'] and start['promptCount']==8192 and start['outputCount']==128,'Started request differs')
    require(result['completed'] is True and result['finishReason']=='length' and result['tokenIDs']==cfg['expectedTokenIDs'],'Incomplete/wrong full target sequence')
    require(not any(k in result for k in ['failure','workerFailure']),'Controller failure retained')
    for key in ['nativeCleanupObserved','ownerDeviceLeaseReleasedObserved','ownerTransportReleased','endpointDiagnosticDrainComplete']:require(result[key]==[True,True] and all(type(v) is bool for v in result[key]),'Missing independent ownership proof: '+key)
    require(result['ownerTermination']==[dict(kind='exited',status=0)]*2,'Owner transport failed')
    pids=[]
    for rank,text in enumerate(result['endpointDiagnosticsBase64']):
        raw=base64.b64decode(text,validate=True);require(0<len(raw)<=65536,'Bounded native diagnostic required');d=parse(raw)
        require(d['schema']=='qwen27b_owner_native_diagnostic_v1' and d['rank']==rank and d['childConstructed'] is True and d['nativeCleanupObserved'] is True and d['termination']==dict(kind='exited',status=0),'Actual native exit/cleanup differs')
        require(d['diagnosticTailBytes']==0 and d['diagnosticTailBase64']=='' and d['diagnosticTailTruncated'] is False,'Native stderr not empty')
        require(type(d['launchedPID']) is int and d['launchedPID']>1,'Missing native PID');pids.append(d['launchedPID'])
    cap=parse(read(case/'capacity.json'));wanted=[x['totalReservedBytes'] for x in cap['ranks']]
    o=result['phaseReservationObservation']
    require(set(o)==set('schema rankReadinessCapacityBytes admittedReservedBytes bytesInUseAfterRetirementBeforeRelease bytesInUseAfterRelease actualRequestRetired'.split()),'Incomplete external reservation observation')
    require(o['schema']=='resident_phase_external_reservation_v1' and o['rankReadinessCapacityBytes']==wanted and all(type(v) is int for v in o['rankReadinessCapacityBytes']),'Actual phase readiness differs from prospective capacity')
    for k in ['admittedReservedBytes','bytesInUseAfterRetirementBeforeRelease']:require(type(o[k]) is int and o[k]==sum(wanted),'Actual admitted bytes differ: '+k)
    require(type(o['bytesInUseAfterRelease']) is int and o['bytesInUseAfterRelease']==0 and o['actualRequestRetired'] is True,'Actual request capacity not retired/released')
    resources=[];journals=[]
    for rank in [0,1]:
        values=[parse(x) for x in read(physical/f'resources-{rank}.jsonl',16*1024*1024).splitlines()]
        require(1<=len(values)<=1400,'Resource count differs')
        minimum=2**64
        for ordinal,v in enumerate(values):
            require(v['ordinal']==ordinal and v['admissible'] is True,'Resource sample refused')
            page=re.search(r'page size of (\d+) bytes',v['rawVMStat']);free=re.search(r'Pages free:\s+(\d+)\.',v['rawVMStat']);swap=re.search(r'used\s*=\s*([0-9.]+)([MG])',v['rawMemory'])
            require(page and free and swap and int(page[1])==16384,'Raw resource parse failed')
            actual=int(page[1])*int(free[1]);pressure=int(v['rawMemory'].splitlines()[0]);used=Decimal(swap[1])*(1024**2 if swap[2]=='M' else 1024**3)
            require(type(v['actualFreeBytes']) is int and actual==v['actualFreeBytes'] and actual>=6*1024**3,'Actual free floor failed')
            require(pressure==v['pressureLevel']==1 and used==Decimal(v['reportedSwapBytes'])==0 and v['acPower'] is True and "Now drawing from 'AC Power'" in v['rawPower'],'Power/swap/pressure differs')
            require(0<=v['startedMonotonicNS']<=v['completedMonotonicNS'] and v['completedMonotonicNS']-v['startedMonotonicNS']<=10**10,'Sample duration differs')
            minimum=min(minimum,actual)
        resources.append(dict(rank=rank,samples=len(values),minimumActualFreeBytes=minimum))
        pre=case/'preflight-1'/f'rank{rank}'
        pr=parse(read(pre/'result.json'));require(pr['passed'] is True and pr['exitCode']==0,'Preflight failed')
        before=read(pre/'stdout');require(digest(before)==pr['stdoutSHA256'],'Preflight pin differs')
        j=parse(before)['journal'];require(j['bytes']==0,'Preflight journal not empty');journals.append(j)
    require(read(physical/'controller.stderr')==b'','Controller stderr nonempty')
    return dict(binding=binding,resources=resources,nativePIDs=pids,preflightJournals=journals,capacities=cap,controller=result,
        physicalExecution=pin(physical/'execution.json'),controllerResult=pin(physical/'controller.stdout.jsonl'))
