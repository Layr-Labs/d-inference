"""Read-only full-reference and bilateral EP numeric/physical evidence joins."""
import argparse
from decimal import Decimal
import hashlib
import json
import math
from pathlib import Path
import re
import sys
ROOT=Path(__file__).resolve().parent
sys.dont_write_bytecode=True
sys.path.insert(0,str(ROOT/'Comparison'));sys.path.insert(0,str(ROOT/'package'))
from recorded_math import parse_json,require,equal,digest,sha_string
from snapshot import snapshot
from contract import canonical_path
from expert_report import expected,report,MODES
from evidence_common import journal,processes,resource_clock,JOURNAL_ID
from jaccl_startup_stderr import validate_retained
from build_binding import verify

def raw(path,bound=1_048_577,empty=False):
    return snapshot(canonical_path(str(path)),bound,empty=empty)['raw']
def read(path,bound=1_048_577):return parse_json(raw(path,bound))

def collection(folder,remote):
    value=read(folder/'collection.json',65536)
    require(value['schema']=='gemma4_full_expert_collection_v1' and value['sshExitCode']==0
            and value['remoteDirectory']==remote and 0<value['archiveBytes']<=128*1024**2,'Bounded actual collection')
    rows=value['files'];require(type(rows) is list and 1<=len(rows)<=128,'Collection file count')
    names=[]
    for row in rows:
        require(set(row)=={'path','bytes','sha256'} and type(row['path']) is str,'Collection row schema')
        path=Path(row['path']);require(not path.is_absolute() and '..' not in path.parts and str(path)==row['path'],'Collection relative path')
        require(type(row['bytes']) is int and 0<=row['bytes']<=16*1024**2,'Collection file size')
        captured=snapshot(canonical_path(str(folder/path)),max(1,row['bytes']),empty=True,keep=False)
        equal([captured['size_bytes'],captured['sha256']],[row['bytes'],sha_string(row['sha256'])],'Captured collection bytes')
        names.append(row['path'])
    require(len(set(names))==len(names),'Duplicate collected file')
    equal(sorted(names),sorted(str(p.relative_to(folder)) for p in folder.rglob('*') if p.is_file() and p.name!='collection.json'),'Collection closure')
    archive=folder.with_suffix('.tar');captured=snapshot(canonical_path(str(archive)),128*1024**2,keep=False)
    equal([captured['size_bytes'],captured['sha256']],[value['archiveBytes'],value['archiveSHA256']],'Actual received archive')

def resources(folder,terminal):
    rows=[parse_json(line) for line in raw(folder/'resources.jsonl',16*1024**2).splitlines()]
    span=resource_clock(rows)
    for row in rows:
        page=re.search(r'page size of (\d+) bytes',row['rawVMStat']);free=re.search(r'Pages free:\s+(\d+)\.',row['rawVMStat'])
        swap=re.search(r'used\s*=\s*([0-9.]+)([MG])',row['rawMemory'])
        require(page and free and swap,'Raw resource fields')
        equal(row['actualFreeBytes'],int(page[1])*int(free[1]),'Actual raw free pages')
        equal(row['pressureLevel'],int(row['rawMemory'].splitlines()[0]),'Actual pressure')
        require(Decimal(row['reportedSwapBytes'])==Decimal(swap[1])*(1024**2 if swap[2]=='M' else 1024**3),'Raw swap arithmetic')
        require(row['acPower'] is ("Now drawing from 'AC Power'" in row['rawPower']),'Raw AC status')
        require(row['actualFreeBytes']>=6*1024**3 and row['pressureLevel']==1 and row['acPower'] is True
                and Decimal(row['reportedSwapBytes'])==0,'Actual resource floor/pressure/swap/AC')
    elapsed=terminal['elapsedSeconds']
    require(type(elapsed) in (int,float) and math.isfinite(elapsed) and 0<elapsed<315
            and span/1e9<=elapsed,'Original absolute parent lifetime')
    return dict(samples=len(rows),minimumActualFreeBytes=min(x['actualFreeBytes'] for x in rows))

def validate_role(case,mode):
    case=canonical_path(str(case),directory=True);index=MODES.index(mode)
    kind='solo' if index==0 else 'pair';host='darkbloom-24' if index==1 else 'darkbloom-48'
    folder=case/kind/mode;outer=read(case/kind/'receipt.json');preparation=read(case/'preparation.json')
    binding=verify();package=read(ROOT/'deployment/package.json')
    package_sha=digest(raw(ROOT/'deployment/package.json'))
    require(package_sha==preparation['packageSHA256'] and preparation['artifactBindingSHA256']==digest(raw(ROOT/'artifact-bindings.json')),'Actual package/preparation binding')
    native=[r for r in package['files'] if r['path']=='bundle/GemmaExpertFullCorrectness']
    require(len(native)==1 and native[0]['sha256']==binding['nativeSHA256'] and native[0]['bytes']==binding['nativeBytes'],'Actual build/package native')
    wanted=['full'] if kind=='solo' else ['expert0','expert1']
    require(outer['status']=='completed' and all(not outer.get(k) for k in ('error','errors','cleanupErrors','collectionErrors','cancellationErrors','peerCancellations')),'No failed/cancelled cohort acceptance')
    equal(sorted(r['mode'] for r in outer['results']),wanted,'Exact completed SSH roles')
    require(all(type(r['exitCode']) is int and r['exitCode']==0 for r in outer['results']),'All SSH exits')
    launched=[r for r in outer['results'] if r['mode']==mode];require(len(launched)==1 and launched[0]['host']==host,'Actual role/host')
    remote=launched[0]['remoteDirectory'];collection(folder,remote)
    require(raw(case/kind/(mode+'.stderr'),8192,empty=True)==b'','Remote parent stderr')
    completed=raw(case/kind/(mode+'.stdout'),65536);require(completed.endswith(b'\n') and completed.count(b'\n')==1,'Completion record')
    terminal_raw=raw(folder/'terminal.json',2*1024**2);terminal=parse_json(terminal_raw)
    equal(parse_json(completed),dict(status='completed',mode=mode,run=remote,terminalSHA256=digest(terminal_raw)),'Actual SSH/terminal join')
    job_raw=raw(case/(mode+'.json'),16384);job=parse_json(job_raw)
    require(raw(folder/'job.json',16384)==job_raw,'Original job bytes/newline')
    equal(digest(job_raw),preparation['jobs'][mode],'Prepared job hash')
    require(job['mode']==mode and job['buildIdentitySHA256']==binding['nativeSHA256']
            and job['rankBuildSHA256']==[binding['nativeSHA256']]*2,'Actual fixed build job')
    require(terminal['schema']=='gemma4_full_expert_terminal_v1' and terminal['mode']==mode
        and terminal['status']=='completed' and terminal['packageSHA256']==package_sha
        and terminal['jobSHA256']==digest(job_raw) and terminal['primaryFailure'] is None
        and terminal['cleanupErrors']==[] and terminal['exitCodes']==[0] and type(terminal['exitCodes'][0]) is int
        and terminal['outputComplete'] is True and terminal['groupsAbsent'] is True
        and terminal['journalEmptyAndProcessesRetired'] is True,'Actual complete native retirement')
    stdout=raw(folder/'native/worker-0.stdout');require(stdout.endswith(b'\n') and stdout.count(b'\n')==1,'Complete bounded native stdout')
    value=parse_json(stdout);equal(value,terminal['result'],'Native stdout/terminal identity')
    stderr=raw(folder/'native/worker-0.stderr',1024,empty=True)
    policy=validate_retained(stderr,'stage1' if index==2 else 'full')
    if index==2:equal(terminal['startupStderr'],policy,'Exact bounded startup diagnostics')
    before=read(folder/'journal-before.json',16384);after=read(folder/'journal-after.json',16384)
    journal(before);journal(after,before)
    expected_hosts=['darkbloom-48'] if kind=='solo' else ['darkbloom-24','darkbloom-48']
    equal(sorted(x['host'] for x in outer['quiescence']),expected_hosts,'Complete host quiescence')
    q=next(x['observed'] for x in outer['quiescence'] if x['host']==host);journal(q['journal'],before);processes(q['processes'])
    gate=read(folder/'gate.json',16384);owner=read(folder/'owner.json',16384)
    require(all(gate[k]==before[k] for k in JOURNAL_ID) and gate['bytes']==0 and gate['exclusiveLockHeld'] is True
            and gate['inheritedAcrossExec'] is True and gate['journalMutationPerformed'] is False,'Same inherited canonical gate')
    processes(gate['processObservation']);pids=terminal['nativePIDs']
    require(len(pids)==1 and type(pids[0]) is int and pids[0]>0 and owner['nativePIDs']==owner['nativePGIDs']==pids
            and gate['ownerPID']==pids[0],'Same-PID native owner and actual group')
    if kind=='pair':
        require(outer['aliasRelease']['exitCode']==0 and outer['aliasRelease']['restored'] is True,'Alias restored after native retirement')
        require(raw(case/kind/'alias.stderr',8192,empty=True)==b'','Alias stderr')
        equal([parse_json(x) for x in raw(case/kind/'alias.stdout',131072).splitlines()],outer['aliasRelease']['records'],'Actual alias final records')
    observed=resources(folder,terminal)
    described_raw=raw(case/('expected-'+mode+'.json'),65536)
    equal(digest(described_raw),preparation['expected'][mode],'Prospective native metadata pin')
    calls=[c for c in preparation['calls'] if c['mode']==mode]
    equal([c['action'] for c in calls],['--describe','--check-arguments']+(['--check-local'] if mode=='expert0' else []),'Actual metadata controls')
    for call in calls:
        log=case/'metadata-controls'/(mode+call['action'])
        output=raw(log/'worker-0.stdout');errors=raw(log/'worker-0.stderr',8192,empty=True)
        require(call['exitCode']==0 and call['outputComplete'] is True and not errors
                and digest(output)==call['stdoutSHA256'] and digest(errors)==call['stderrSHA256'],'Actual metadata child result')
        control=parse_json(output)
        if call['action']!='--check-local':equal(control,parse_json(described_raw),'Actual metadata stdout/expected join')
        else:require(control['nativeExecuted'] is False and control['encoding']['oversizedRefused'] is True,'Actual encoding/CPU controls')
    description=parse_json(described_raw);prompt_raw=raw(ROOT/'deployment/prompt.ids.json',4096)
    prompt=expected(description,prompt_raw)
    original=description['original']
    for key in ('requestID','membershipEpoch','buildIdentitySHA256','promptFileSHA256'):equal(original[key],job[key],'Job/description '+key)
    equal(description['globalExpertIDsByRank'],job['globalExpertIDsByRank'],'Job ownership')
    numeric=report(value,description,prompt,folder/'sidecars',index)
    proof=dict(mode=mode,nativePID=pids[0],terminalSHA256=digest(terminal_raw),jobSHA256=digest(job_raw),
        stdoutSHA256=digest(stdout),resourceSamples=observed['samples'],minimumActualFreeBytes=observed['minimumActualFreeBytes'],
        sameCanonicalJournal=True,completeEOFAndNaturalZero=True,processTableRawRetained=False)
    return dict(job=job,expected=description,numeric=numeric,proof=proof)

def compare(case):
    values=[validate_role(case,m) for m in MODES] # full reference first
    full=values[0];ignored={'mode','outputDirectory'}
    for candidate in values[1:]:
        equal({k:v for k,v in candidate['job'].items() if k not in ignored},
              {k:v for k,v in full['job'].items() if k not in ignored},'Exact matched input/build/epoch/ownership')
        equal(candidate['expected']['scopeSHA256'],full['expected']['scopeSHA256'],'Same native experiment scope')
        for key in ('tokens','rows','state','layers'):
            require(candidate['numeric'][key]==full['numeric'][key],'Full EP/reference mismatch: '+key)
    equal(values[1]['numeric']['exchanges'],values[2]['numeric']['exchanges'],'Bilateral actual exchange transcript')
    require(values[1]['proof']['nativePID']>0 and values[2]['proof']['nativePID']>0,'Actual rank processes')
    return dict(schema='gemma4_full_expert_comparison_v1',passed=True,selectedTokenIDs=full['numeric']['tokens'],
        vocabularySize=262144,rowsComparedPerRank=2,stateEntriesComparedPerRank=90,finalFrontier=33,
        exactNativeBytes=True,toleranceApplied=False,roles=[v['proof'] for v in values],
        scopeSHA256=full['expected']['scopeSHA256'],throughputMeasurementValid=False,
        encryptedRDMAEstablished=False,runtimeServingEnabled=False,crossHostClocksCompared=False)

if __name__=='__main__':
    parser=argparse.ArgumentParser(allow_abbrev=False);parser.add_argument('case',type=Path);args=parser.parse_args()
    result=compare(args.case)
    with (args.case/'comparison.json').open('x') as stream:json.dump(result,stream,indent=2,allow_nan=False)
    print(json.dumps(result,sort_keys=True))
