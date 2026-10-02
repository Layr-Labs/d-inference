"""Read-only acceptance of retained native, process, resource and pair evidence."""
import argparse
import hashlib
import json
from pathlib import Path
import sys
ROOT=Path(__file__).resolve().parent
sys.path.insert(0,str(ROOT/'package'))
from binding_common import canonical, parse, require, same
from deploy import REMOTE, digest, verify_sources
from expert_results import validate_result, validate_pair
from gemma_inputs import product, validate_job, write_json
from jaccl_startup_stderr import validate_retained
from mtp_journal import require_empty
from reference_resources import sample_local, validate_local

def raw(path,bound=4*1024**2):
    require(not path.is_symlink() and path.is_file() and path.stat().st_nlink==1 and 0<=path.stat().st_size<=bound,'Unsafe returned file '+str(path))
    return path.read_bytes()
def read(path,bound=4*1024**2):return parse(raw(path,bound))
def one_line(path,bound=4*1024**2):
    data=raw(path,bound);require(data.endswith(b'\n') and data.count(b'\n')==1,'Expected one complete JSON line')
    return parse(data)
def resources(path):
    data=raw(path,8*1024**2);require(data.endswith(b'\n'),'Incomplete resource log')
    rows=[parse(line) for line in data.splitlines()];require(2<=len(rows)<=2000,'Resource sample count')
    require(rows[0]['phase']=='prelaunch' and rows[-1]['phase']=='postflight','Resource lifetime boundaries')
    last=0
    for row in rows:
        validate_local(row);require(row['startedMonotonicNS']>=last,'Resource time order');last=row['completedMonotonicNS']
        values={'/usr/sbin/sysctl':row['rawMemory'],'/usr/bin/vm_stat':row['rawVMStat'],'/usr/bin/pmset':row['rawPower']}
        replay=sample_local(lambda argv:values[argv[0]])
        for name in ['actualFreeBytes','pressureLevel','reportedSwapBytes','acPower']:same(row[name],replay[name],'Raw OS resource '+name)
    return dict(count=len(rows),minimumActualFreeBytes=min(x['actualFreeBytes'] for x in rows),sha256=digest(path))
def validate_rank(directory,mode,job,package_sha,artifact,remote):
    validate_job(job);returned=directory/mode
    same(read(returned/'job.json'),job,'Returned exact job')
    expected_job=canonical(job)+b'\n';require(raw(returned/'job.json')==expected_job,'Returned canonical job bytes')
    jobsha=hashlib.sha256(expected_job).hexdigest()
    terminal=read(returned/'terminal.json');parent=one_line(directory/(mode+'.stdout'))
    require(raw(directory/(mode+'.stderr'))==b'','Remote supervisor stderr')
    same(parent,dict(status='completed',mode=mode,run=remote,terminalSHA256=digest(returned/'terminal.json')),'Parent terminal receipt')
    require(terminal['schema']=='gemma4_expert_terminal_v1' and terminal['status']=='completed' and terminal['mode']==mode
        and terminal['packageSHA256']==package_sha and terminal['jobSHA256']==jobsha and terminal['primaryFailure'] is None
        and terminal['cleanupErrors']==[] and terminal['exitCodes']==[0] and terminal['outputComplete'] is True
        and terminal['groupsAbsent'] is True and terminal['journalEmptyAndProcessesRetired'] is True
        and 0<terminal['elapsedSeconds']<315,'Actual terminal/cleanup contract')
    require(terminal['encryptedRDMAEstablished'] is False and terminal['externalHTTPTTFTMeasured'] is False,'Scope claims')
    result=one_line(returned/'native/worker-0.stdout',2*1024**2+1)
    same(result,terminal['result'],'Actual native stdout/terminal join');validate_result(result,job)
    stderr=validate_retained(raw(returned/'native/worker-0.stderr',1024),mode)
    if mode=='stage1':same(stderr,terminal['startupStderr'],'Retained JACCL startup observations')
    require(raw(returned/'native/worker-0.stdin',1024)==b'','No alternate native stdin protocol')
    before=read(returned/'journal-before.json');after=read(returned/'journal-after.json');require_empty(before);require_empty(after,before)
    for value in (before,after):require(value['exclusiveObservationLockAcquired'] is True and value['journalMutationPerformed'] is False,'Actual canonical lock observations')
    owner=read(returned/'owner.json');gate=read(returned/'gate.json');launch=read(returned/'launch.json')
    pids=terminal['nativePIDs'];require(len(pids)==1 and type(pids[0]) is int and pids[0]>1,'Actual native PID')
    require(owner['nativePIDs']==pids and owner['nativePGIDs']==pids and gate['ownerPID']==pids[0]
        and gate['exclusiveLockHeld'] is True and gate['inheritedAcrossExec'] is True
        and gate['journalMutationPerformed'] is False and gate['protocolReleaseACK'] is False
        and gate['processObservation']['prohibited']==[],'Same owned native and inherited canonical gate')
    for name in ['path','directoryDevice','directoryInode','fileDevice','fileInode']:same(gate[name],before[name],'Gate/journal identity')
    require(gate['bytes']==0 and owner['parentPID']>1 and owner['parentPID']!=pids[0],'Gate owner identity')
    expected_args=['--'+job['kind']];inner_sha=None
    if job['kind']=='checkpoint':expected_args=['--checkpoint',job['modelDirectory'],'--layer',str(job['layer'])]
    if job['kind']=='rdma':
        inner=canonical(job['nativeJob'])+b'\n';require(raw(returned/'native-job.json',16384)==inner,'Original RDMA inner bytes')
        inner_sha=hashlib.sha256(inner).hexdigest();expected_args=['--execute',remote+'/native-job.json']
    require(launch['binary']==REMOTE+'/bundle/'+product(job) and launch['job']==remote+'/job.json'
        and launch['jobSHA256']==jobsha and launch['arguments']==expected_args and launch['nativeJobSHA256']==inner_sha
        and launch['binaryIdentity'][3]==artifact['bytes'],'Actual binary/job/argv launch join')
    expected_env=dict(PATH='/usr/bin:/bin:/usr/sbin:/sbin',HOME='/Users/gaj',LANG='C',
        DARKBLOOM_CBV2_ATTN_QUERY_BLOCK='128',DARKBLOOM_BF16_WEIGHTS='1',MLX_ENABLE_TF32='1')
    if job['kind']=='rdma':expected_env.update(JACCL_RANK=str(job['nativeJob']['rank']),JACCL_IBV_DEVICES=REMOTE+'/matrix.json',JACCL_COORDINATOR='192.0.2.250:51361')
    same(launch['environment'],expected_env,'Native arithmetic/transport environment')
    require(job['nativeSHA256']==artifact['sha256'],'Actual native artifact identity')
    return result,dict(mode=mode,nativePID=pids[0],nativeSHA256=artifact['sha256'],jobSHA256=jobsha,
        terminalSHA256=digest(returned/'terminal.json'),nativeStdoutSHA256=digest(returned/'native/worker-0.stdout'),resources=resources(returned/'resources.jsonl'))
def validate(directory):
    bindings=verify_sources();require(directory.parent.parent==ROOT/'cases' and directory.name in ('solo','pair'),'Local cohort path')
    receipt=read(directory/'receipt.json');package=read(ROOT/'deployment/package.json');package_sha=digest(ROOT/'deployment/package.json')
    kind=directory.name;selected=[('full','darkbloom-48')] if kind=='solo' else [('stage0','darkbloom-24'),('stage1','darkbloom-48')]
    require(receipt['schema']=='gemma4_expert_parent_v1' and receipt['status']=='completed' and receipt['kind']==kind
        and receipt['packageSHA256']==package_sha,'Original parent acceptance')
    require(not any(receipt.get(k) for k in ['errors','error','cleanupErrors','collectionErrors','cancellationErrors','peerCancellations','quiescenceRetryErrors']),'Parent retained failure')
    expected=[];results=[];observations=[]
    for mode,host in selected:
        remote=REMOTE+'/runs/'+directory.parent.name+'-'+mode
        expected.append(dict(mode=mode,host=host,exitCode=0,remoteDirectory=remote))
        job=read(directory.parent/(mode+'.json'));require((job['kind']=='rdma')==(kind=='pair'),'Exact mode selection')
        artifact=next(x for x in bindings['products'] if x['product']==product(job))
        installed=next(x for x in package['files'] if x['path']=='bundle/'+product(job))
        require(installed['sha256']==artifact['sha256'] and installed['bytes']==artifact['bytes'],'Installed actual artifact')
        result,observation=validate_rank(directory,mode,job,package_sha,artifact,remote);results.append(result);observations.append(observation)
    same(sorted(receipt['results'],key=lambda x:x['mode']),sorted(expected,key=lambda x:x['mode']),'Both actual remote supervisors')
    require(len(receipt['quiescence'])==len(selected) and {x['host'] for x in receipt['quiescence']}=={x[1] for x in selected},'All original physical owners retired')
    for value in receipt['quiescence']:
        require_empty(value['observed']['journal']);require(value['observed']['processes']['prohibited']==[],'Actual postflight absence')
    if kind=='pair':
        require(receipt['aliasReady']==dict(state='ready',address='169.254.70.47',bridgeAndManagementStable=True),'Actual mapped RDMA alias')
        release=receipt['aliasRelease'];require(release['exitCode']==0 and release['restored'] is True and len(release['records'])==1,'Alias actual release')
        same(one_line(directory/'alias.stdout'),release['records'][0],'Raw alias release record')
        require(raw(directory/'alias.stderr',4096)==b'' and release['records'][0]['restored'] is True
            and not release['records'][0].get('error') and not release['records'][0].get('cleanupError'),'Alias restoration result')
        validate_pair(*results)
    return dict(schema='gemma4_expert_physical_acceptance_v1',passed=True,kind=kind,packageSHA256=package_sha,
        parentReceiptSHA256=digest(directory/'receipt.json'),observations=observations,
        numericalScope='one-layer whole-expert original-topK-slot equality',encryptedRDMA=False,
        fullDecoderQualified=False,throughputMeasurementValid=False,productionDeviceOnlyRoutingQualified=False)
def main():
    p=argparse.ArgumentParser(allow_abbrev=False);p.add_argument('directory',type=Path);a=p.parse_args()
    value=validate(a.directory.resolve());write_json(a.directory/'validation.json',value);print(json.dumps(value))
if __name__=='__main__':main()
