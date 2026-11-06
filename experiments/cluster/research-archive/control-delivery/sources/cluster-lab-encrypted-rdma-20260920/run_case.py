"""Run one explicitly selected two-host lab payload and retain all outcomes."""
import argparse
from concurrent.futures import ThreadPoolExecutor,as_completed
import hashlib
import json
import os
from pathlib import Path
import shlex
import select
import selectors
import subprocess
import sys
import tarfile
import time
import uuid
import stat
import resource

ROOT=Path(__file__).resolve().parent
sys.path.insert(0,str(ROOT/'package'))
from alias import Alias
from parent_settings import SSH
from deploy import REMOTE, PRODUCTS, digest, verify_sources
from gemma_inputs import PAYLOADS, product, validate_job, write_json
from lab_secret import commitment

def ssh(host,args,**kwargs):
    return subprocess.run(SSH+[host,shlex.join(args)],capture_output=True,**kwargs)

CREATE=r'''
import json,os,pathlib,sys
base=pathlib.Path('/Users/developer/DarkbloomDev/cluster-lab-encrypted-rdma-20260920')
sys.path.insert(0,str(base))
from gemma_inputs import validate_job,write_json
job=json.load(sys.stdin);validate_job(job);root=pathlib.Path(sys.argv[1])
assert root.parent==base/'runs' and root.name and all(c.isalnum() or c in '-_' for c in root.name)
os.umask(0o077);root.parent.mkdir(mode=0o700,exist_ok=True)
assert root.parent.resolve()==root.parent
root.mkdir(mode=0o700);write_json(root/'job.json',job)
if job['nativeJob'] is not None:write_json(root/'native-job.json',job['nativeJob'])
'''
QUIESCENT=r'''
import json,pathlib,sys,time
root=pathlib.Path('/Users/developer/DarkbloomDev/cluster-lab-encrypted-rdma-20260920')
sys.path.insert(0,str(root))
from mtp_journal import device_directory,observe,require_empty
from target_processes import observe as processes
j=observe(device_directory());require_empty(j)
p=processes(time.monotonic()+4);assert not p['prohibited']
print(json.dumps(dict(journal=j,processes=p)))
'''
CANCEL=r'''
import hashlib,json,os,pathlib,sys
job=pathlib.Path(sys.argv[1]);wanted=sys.argv[2]
assert job.name=='job.json' and job.parent.parent==pathlib.Path('/Users/developer/DarkbloomDev/cluster-lab-encrypted-rdma-20260920/runs')
assert hashlib.sha256(job.read_bytes()).hexdigest()==wanted
path=job.parent/'cancellation.json'
value={'schema':'lab_record_cancellation_v1','jobSHA256':wanted}
if path.exists():assert json.loads(path.read_bytes())==value
else:
 os.umask(0o077)
 with path.open('x') as stream:json.dump(value,stream,sort_keys=True)
'''

def prepare(name,payload):
    bindings=verify_sources()
    package=json.loads((ROOT/'deployment/package.json').read_bytes())
    artifact=bindings['products'][0]
    row=next(x for x in package['files'] if x['path']=='bundle/'+PRODUCTS[0])
    assert row['sha256']==artifact['sha256'] and row['bytes']==artifact['bytes']
    directory=ROOT/'cases'/name;directory.mkdir(mode=0o700,parents=True)
    secret_dir=ROOT/'private-secrets';secret_dir.mkdir(mode=0o700,exist_ok=True)
    assert secret_dir.resolve()==secret_dir and secret_dir.stat().st_mode&0o077==0
    secret=os.urandom(32);secret_path=secret_dir/(name+'.secret')
    fd=os.open(secret_path,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
    try:
        assert os.write(fd,secret)==32;os.fsync(fd)
    finally:os.close(fd)
    run_id=str(uuid.uuid4())
    for rank,mode in enumerate(('stage0','stage1')):
        native=dict(schema='lab_authenticated_rdma_component_v1',identityKind='ssh_host_key_lab_only',runID=run_id,
            rank=rank,payloadBytes=payload,warmups=3,measurements=20,timeoutSeconds=120,
            hostKeySHA256=[x['hostKeySHA256'] for x in bindings['hosts']],nativeBuildSHA256=[artifact['sha256']]*2,
            sourceSnapshotSHA256=bindings['sourceSnapshotSHA256'],mlxArtifactSHA256=bindings['mlxArtifactSHA256'],
            secretCommitmentSHA256=commitment(secret),expectedHardware=[x['hardware'] for x in bindings['hosts']],
            expectedOSBuild=[x['osBuild'] for x in bindings['hosts']])
        job=dict(schema='lab_record_physical_job_v1',kind='rdma',mode=mode,nativeSHA256=artifact['sha256'],timeoutSeconds=120,nativeJob=native)
        validate_job(job);write_json(directory/(mode+'.json'),job)
    print(str(directory))

def collect(host,remote,directory):
    archive_path=directory.with_suffix('.tar');stderr_path=directory.with_suffix('.tar.stderr')
    command=SSH+[host,shlex.join(['/usr/bin/tar','-cf','-','-C',remote,'.'])]
    received=0;deadline=time.monotonic()+180;child=None
    with archive_path.open('xb') as archive,stderr_path.open('xb') as errors:
        child=subprocess.Popen(command,stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=errors)
        selector=selectors.DefaultSelector();selector.register(child.stdout,selectors.EVENT_READ)
        try:
            while selector.get_map():
                assert time.monotonic()<deadline,'Collection deadline'
                for key,_ in selector.select(min(1,deadline-time.monotonic())):
                    block=os.read(key.fileobj.fileno(),1024*1024)
                    if not block:selector.unregister(key.fileobj);continue
                    received+=len(block)
                    assert received<=64*1024**2,'Collection receive bound exceeded'
                    archive.write(block)
            assert child.wait(timeout=max(0.001,deadline-time.monotonic()))==0,'Remote archive failed'
        finally:
            selector.close();child.stdout.close()
            if child.poll() is None:child.kill()
            child.wait(timeout=5)
    assert stderr_path.stat().st_size==0,'Collection emitted stderr'
    directory.mkdir(mode=0o700)
    with tarfile.open(archive_path,'r:') as tar:
        for item in tar:
            path=Path(item.name)
            assert not path.is_absolute() and '..' not in path.parts and not item.issym() and not item.islnk()
            dest=directory/path
            if item.isdir():dest.mkdir(parents=True,exist_ok=True);continue
            assert item.isfile() and item.size<=16*1024**2;dest.parent.mkdir(parents=True,exist_ok=True)
            with dest.open('xb') as output:
                source=tar.extractfile(item)
                for block in iter(lambda:source.read(1024*1024),b''):output.write(block)

def await_alias_expiry(alias,started):
    """Keep the release channel open; the original remote lease owns its expiry."""
    if alias.process is None:return dict(notStarted=True,restored=True)
    output=bytearray();eof=False
    while time.monotonic()<started+625 and not (eof and alias.process.poll() is not None):
        if not eof and select.select([alias.process.stdout],[],[],0.25)[0]:
            block=os.read(alias.process.stdout.fileno(),65536)
            if not block:eof=True
            else:
                output.extend(block)
                if len(output)>131072:raise ValueError('Alias expiry output exceeds bound')
    require_retired=alias.process.poll() is not None
    (alias.output/'alias-expiry.stdout').write_bytes(output)
    values=[json.loads(line) for line in output.splitlines() if line.strip()]
    return dict(explicitReleaseSent=False,leaseExpiredWithoutNativeRetirementProof=True,
                processRetired=require_retired,exitCode=alias.process.returncode,
                records=values,restored=require_retired and bool(values) and values[-1].get('restored') is True)

def run(name,kind):
    verify_sources()
    assert kind=='pair'
    directory=ROOT/'cases'/name;out=directory/kind;out.mkdir(mode=0o700)
    secret_path=ROOT/'private-secrets'/(name+'.secret')
    fd=os.open(secret_path,os.O_RDONLY|os.O_NOFOLLOW)
    try:
        info=os.fstat(fd);assert stat.S_ISREG(info.st_mode) and info.st_uid==os.geteuid() and info.st_nlink==1 and info.st_mode&0o077==0 and info.st_size==32
        secret=os.read(fd,33);assert len(secret)==32
    finally:os.close(fd)
    selected=[('stage0','darkbloom-24'),('stage1','darkbloom-48')]
    package_sha=digest(ROOT/'deployment/package.json')
    for mode,host in selected:
        raw=(directory/(mode+'.json')).read_bytes()
        job=json.loads(raw);validate_job(job)
        assert commitment(secret)==job['nativeJob']['secretCommitmentSHA256']
        assert (job['kind']=='rdma')==(kind=='pair') and job['mode']==mode
        assert job['nativeSHA256']==next(x['sha256'] for x in json.loads((ROOT/'deployment/package.json').read_bytes())['files'] if x['path']=='bundle/'+product(job))
        p=ssh(host,['/usr/bin/python3','-c',CREATE,REMOTE+'/runs/'+name+'-'+mode],input=raw,timeout=15)
        assert p.returncode==0 and not p.stderr, 'Job preparation failed'
    alias=Alias(out);record={'schema':'lab_record_parent_v1','status':'failed','kind':kind,'packageSHA256':package_sha,'results':[]};started=time.monotonic()
    try:
        if kind=='pair':record['aliasReady']=alias.start()
        def invoke(row):
            mode,host=row;raw=(directory/(mode+'.json')).read_bytes()
            remote=REMOTE+'/runs/'+name+'-'+mode
            p=ssh(host,['/usr/bin/python3','-B',REMOTE+'/run_benchmark.py','--package-sha256',package_sha,
                        '--job',remote+'/job.json','--job-sha256',hashlib.sha256(raw).hexdigest()],input=secret,timeout=165)
            (out/(mode+'.stdout')).write_bytes(p.stdout);(out/(mode+'.stderr')).write_bytes(p.stderr)
            return dict(mode=mode,host=host,exitCode=p.returncode,remoteDirectory=remote)
        with ThreadPoolExecutor(max_workers=len(selected)) as executor:
            futures={executor.submit(invoke,row):row for row in selected};cancelled=False
            for future in as_completed(futures):
                failed=False
                try:
                    result=future.result();record['results'].append(result);failed=result['exitCode']!=0
                except BaseException as error:
                    failed=True;record.setdefault('errors',[]).append(type(error).__name__+': '+str(error))
                if failed and not cancelled:
                    cancelled=True
                    for pending,(mode,host) in futures.items():
                        if pending.done():continue
                        raw=(directory/(mode+'.json')).read_bytes()
                        try:
                            c=ssh(host,['/usr/bin/python3','-c',CANCEL,REMOTE+'/runs/'+name+'-'+mode+'/job.json',
                                        hashlib.sha256(raw).hexdigest()],timeout=10)
                            if c.returncode or c.stderr:raise ValueError('Peer cancellation delivery failed')
                            record.setdefault('peerCancellations',[]).append(mode)
                        except Exception as error:record.setdefault('cancellationErrors',[]).append(str(error))
        record['status']='completed' if len(record['results'])==len(selected) and all(x['exitCode']==0 for x in record['results']) else 'failed'
    except BaseException as error:
        record['error']=type(error).__name__+': '+str(error)
    finally:
        record['quiescence']=[]
        for mode,host in selected:
            try:
                p=ssh(host,['/usr/bin/python3','-c',QUIESCENT],timeout=10)
                assert p.returncode==0 and not p.stderr,'Canonical owner or process remains'
                record['quiescence'].append(dict(host=host,observed=json.loads(p.stdout)))
            except BaseException as error:
                record['status']='failed';record.setdefault('cleanupErrors',[]).append(str(error))
        # The remote alias also has an independent 600-second expiry. Normally
        # release immediately after both actual native owners have retired.
        if kind=='pair':
            if len(record['quiescence'])!=len(selected):
                record['status']='failed'
                # Re-observe within the remaining bounded alias window; never
                # clear journals or signal unrelated processes to obtain a pass.
                until=started+540
                while time.monotonic()<until and len(record['quiescence'])!=len(selected):
                    time.sleep(1)
                    rows=[]
                    for mode,host in selected:
                        try:
                            p=ssh(host,['/usr/bin/python3','-c',QUIESCENT],timeout=10)
                            if p.returncode==0 and not p.stderr:rows.append(dict(host=host,observed=json.loads(p.stdout)))
                        except Exception as error:
                            record.setdefault('quiescenceRetryErrors',[]).append(str(error))
                    if len(rows)==len(selected):record['quiescence']=rows
            try:
                if len(record['quiescence'])==len(selected):record['aliasRelease']=alias.release()
                else:record['aliasExpiry']=await_alias_expiry(alias,started)
                if not record.get('aliasRelease',{}).get('restored'):record['status']='failed'
            except BaseException as error:
                record['status']='failed';record.setdefault('cleanupErrors',[]).append(str(error))
        for mode,host in selected:
            try:collect(host,REMOTE+'/runs/'+name+'-'+mode,out/mode)
            except BaseException as error:record['status']='failed';record.setdefault('collectionErrors',[]).append(str(error))
        try:
            actual=secret_path.lstat();assert (actual.st_dev,actual.st_ino)==(info.st_dev,info.st_ino)
            secret_path.unlink();record['localSecretFileRemoved']=True
        except BaseException as error:record['status']='failed';record.setdefault('cleanupErrors',[]).append(str(error))
        if record['status']=='completed':
            try:
                from expert_results import join_results
                reports=[];jobs=[]
                for mode,_ in selected:
                    returned=out/mode
                    terminal=json.loads((returned/'terminal.json').read_bytes())
                    native=json.loads((returned/'native/worker-0.stdout').read_bytes())
                    assert terminal['status']=='completed' and terminal['result']==native and terminal['exitCodes']==[0] and terminal['groupsAbsent'] and terminal['journalEmptyAndProcessesRetired'] and not terminal['cleanupErrors'] and terminal['privateSecretFileAbsent'] is True
                    assert (returned/'native/worker-0.stdin').read_bytes()==b''
                    reports.append(native);jobs.append(json.loads((directory/(mode+'.json')).read_bytes()))
                joined=join_results(reports,jobs);write_json(out/'comparison.json',joined)
                record['comparisonSHA256']=digest(out/'comparison.json')
            except BaseException as error:record['status']='failed';record.setdefault('comparisonErrors',[]).append(str(error))
        record['elapsedSeconds']=time.monotonic()-started
        (out/'receipt.json').write_text(json.dumps(record,indent=2)+'\n')
    print(json.dumps(record))
    return 0 if record['status']=='completed' else 1

def main():
    os.umask(0o077);resource.setrlimit(resource.RLIMIT_CORE,(0,0))
    p=argparse.ArgumentParser(allow_abbrev=False)
    p.add_argument('action',choices=['prepare','pair']);p.add_argument('--name',required=True)
    p.add_argument('--payload',type=int,choices=PAYLOADS,default=131072);a=p.parse_args()
    assert a.name and len(a.name)<=64 and all(c.isalnum() or c in '-_' for c in a.name)
    if a.action=='prepare':prepare(a.name,a.payload);return 0
    return run(a.name,'pair')

if __name__=='__main__':raise SystemExit(main())
