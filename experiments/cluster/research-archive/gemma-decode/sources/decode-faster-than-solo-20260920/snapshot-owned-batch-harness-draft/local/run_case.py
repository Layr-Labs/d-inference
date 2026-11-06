"""Run one explicitly selected solo or pair cohort and retain all outcomes."""
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

ROOT=Path(__file__).resolve().parent
sys.path.insert(0,str(ROOT/'package'))
from alias import Alias
from parent_settings import SSH
from deploy import REMOTE, PRODUCT, digest

def ssh(host,args,**kwargs):
    return subprocess.run(SSH+[host,shlex.join(args)],capture_output=True,**kwargs)

CREATE=r'''
import hashlib,json,os,pathlib,sys
payload=json.load(sys.stdin);job=payload['job'];config=payload['config'];root=pathlib.Path(job['outputDirectory']).parent
assert root.parent==pathlib.Path('/Users/developer/DarkbloomDev/gemma4-local-mtp-owned-batch-20260920-v1/runs')
os.umask(0o077);root.parent.mkdir(mode=0o700,exist_ok=True);root.mkdir(mode=0o700)
raw=(json.dumps(job,sort_keys=True,separators=(',',':'))+'\n').encode()
assert config['benchmarkJob']==str(root/'job.json') and config['benchmarkJobSHA256']==hashlib.sha256(raw).hexdigest()
(root/'job.json').write_bytes(raw)
(root/'local-mtp.json').write_text(json.dumps(config,sort_keys=True,separators=(',',':'))+'\n')
'''
QUIESCENT=r'''
import json,pathlib,sys,time
root=pathlib.Path('/Users/developer/DarkbloomDev/gemma4-local-mtp-owned-batch-20260920-v1')
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
assert job.name=='job.json' and job.parent.parent==pathlib.Path('/Users/developer/DarkbloomDev/gemma4-local-mtp-owned-batch-20260920-v1/runs')
assert hashlib.sha256(job.read_bytes()).hexdigest()==wanted
path=job.parent/'cancellation.json'
value={'schema':'gemma4_benchmark_cancellation_v1','jobSHA256':wanted}
if path.exists():assert json.loads(path.read_bytes())==value
else:
 os.umask(0o077)
 with path.open('x') as stream:json.dump(value,stream,sort_keys=True)
'''

def prepare(name,count,cut,capture,chunk,policy,match,depth,operation,output_count=16):
    assert type(output_count) is int and output_count in (16,128)
    assert count in (128,4096) and (cut,chunk,policy,match)==(7,64,'serial',None)
    assert depth in (1,2) and operation == 'execute-solo'
    directory=ROOT/'cases'/name;directory.mkdir(mode=0o700,parents=True)
    requests=[str(uuid.uuid4()) for _ in range(4)]
    common=dict(schema='gemma4_resident_benchmark_v1',modelDirectory='/Users/developer/DarkbloomDev/models/Gemma4-26B',
                metadataDirectory=REMOTE+'/metadata',promptFile=REMOTE+f'/prompts/prompt-{count}.json',
                promptFileSHA256=digest(ROOT/'prompts'/f'prompt-{count}.json'),
                requestIDs=requests,membershipEpoch=str(uuid.uuid4()),
                buildIdentitySHA256=digest(ROOT/'deployment/bundle'/PRODUCT),residualDType='bfloat16',
                promptCount=count,chunkSize=chunk,outputCount=output_count,timeoutSeconds=300,captureEvidence=capture if operation=='execute-solo' else False,cut=cut)
    if match is not None:
        assert match and all(c.isalnum() or c in '-_' for c in match)
        prior=json.loads((ROOT/'cases'/match/'full.json').read_bytes())
        ignored={'requestIDs','membershipEpoch','mode','outputDirectory','prefillPolicy'}
        assert {k:v for k,v in prior.items() if k not in ignored} == {k:v for k,v in common.items() if k not in ignored}, 'Matched source workload differs'
        common.update(requestIDs=prior['requestIDs'],membershipEpoch=prior['membershipEpoch'])
    for mode in ['full']:
        job=dict(common,mode=mode,outputDirectory=REMOTE+'/runs/'+name+'-'+mode+'/sidecars')
        job['prefillPolicy']='serial' if mode=='full' else policy
        raw=(json.dumps(job,sort_keys=True,separators=(',',':'))+'\n').encode()
        (directory/(mode+'.json')).write_bytes(raw)
        config=dict(schema='gemma4_local_mtp_cohort_job_v1',benchmarkJob=str(Path(job['outputDirectory']).parent/'job.json'),
                    benchmarkJobSHA256=hashlib.sha256(raw).hexdigest(),
                    assistantModelDirectory='/Users/developer/DarkbloomDev/models/Gemma4-26B-assistant-bb94eae1',
                    assistantMetadataDirectory=REMOTE+'/assistant-metadata',maximumDraftTokens=depth,captureEvidence=capture)
        (directory/'local-mtp.json').write_text(json.dumps(config,sort_keys=True,separators=(',',':'))+'\n')
        (directory/'operation.json').write_text(json.dumps(dict(operation=operation))+'\n')
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
                    assert received<4*1024**3+64*1024**2,'Collection receive bound exceeded'
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
            assert item.isfile() and item.size<=64*1024**2;dest.parent.mkdir(parents=True,exist_ok=True)
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
    assert kind=='solo', 'Local target/assistant cohorts are full/48 only'
    directory=ROOT/'cases'/name;out=directory/kind;out.mkdir(mode=0o700)
    selected=[('full','darkbloom-48')] if kind=='solo' else [('stage0','darkbloom-24'),('stage1','darkbloom-48')]
    package_sha=digest(ROOT/'deployment/package.json')
    config=json.loads((directory/'local-mtp.json').read_bytes())
    operation=json.loads((directory/'operation.json').read_bytes())['operation']
    assert operation == 'execute-solo'
    for mode,host in selected:
        raw=(directory/(mode+'.json')).read_bytes()
        p=ssh(host,['/usr/bin/python3','-c',CREATE],input=json.dumps(dict(job=json.loads(raw),config=config)).encode(),timeout=15)
        assert p.returncode==0 and not p.stderr, 'Job preparation failed'
    alias=Alias(out);record={'status':'failed','kind':kind,'results':[]};started=time.monotonic()
    try:
        if kind=='pair':record['aliasReady']=alias.start()
        def invoke(row):
            mode,host=row;raw=(directory/(mode+'.json')).read_bytes()
            remote=REMOTE+'/runs/'+name+'-'+mode
            p=ssh(host,['/usr/bin/python3','-B',REMOTE+'/run_benchmark.py','--package-sha256',package_sha,
                        '--job',remote+'/job.json','--job-sha256',hashlib.sha256(raw).hexdigest(),
                        '--local-mtp-config-sha256',digest(directory/'local-mtp.json'),
                        '--native-operation',operation],timeout=345)
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
        record['elapsedSeconds']=time.monotonic()-started
        (out/'receipt.json').write_text(json.dumps(record,indent=2)+'\n')
    print(json.dumps(record))
    return 0 if record['status']=='completed' else 1

def main():
    p=argparse.ArgumentParser(allow_abbrev=False)
    p.add_argument('action',choices=['prepare','solo']);p.add_argument('--name',required=True)
    p.add_argument('--prompt',type=int,choices=[128,4096],default=4096)
    p.add_argument('--cut',type=int,choices=[7],default=7)
    p.add_argument('--chunk',type=int,choices=[64],default=64)
    p.add_argument('--policy',choices=['serial'],default='serial')
    p.add_argument('--match',help='Existing case with exactly the same workload and native build')
    p.add_argument('--capture',action='store_true')
    p.add_argument('--output-count',type=int,choices=[16,128],default=16)
    p.add_argument('--depth',type=int,choices=[1,2],default=2)
    p.add_argument('--native-operation',choices=['execute-solo'],default='execute-solo')
    a=p.parse_args()
    assert a.name and all(c.isalnum() or c in '-_' for c in a.name)
    if a.action=='prepare':prepare(a.name,a.prompt,a.cut,a.capture,a.chunk,a.policy,a.match,a.depth,a.native_operation,a.output_count);return 0
    return run(a.name,a.action)

if __name__=='__main__':raise SystemExit(main())
