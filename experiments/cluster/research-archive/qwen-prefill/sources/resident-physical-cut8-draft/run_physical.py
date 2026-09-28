#!/usr/bin/env python3
"""Two explicit SSH peers, one cut12 serial resident cohort, separate remote retirement."""
import argparse
from datetime import datetime,timezone
import hashlib
import os
from pathlib import Path
import shlex
import signal
import subprocess
import sys
import time
import uuid

sys.dont_write_bytecode=True
from binding_inputs import snapshot
from physical_common import (Pins,canonical,exact,fields,host,make_jobs,parse,path,read_plan,require,
    verify_launcher,write_new,write_json)
from rank_validation import RankValidator
from jaccl_stderr import validate_retry_bytes
from solo_resources import validate_local
from worker_adapter import ResidentWorkerCohort
from worker_contract import WorkerSpec,SUFFIXES
from worker_processes import cleanup_error_text

SSH_OPTIONS=('-T','-o','BatchMode=yes','-o','StrictHostKeyChecking=yes','-o','ConnectionAttempts=1',
             '-o','ConnectTimeout=5','-o','ServerAliveInterval=1','-o','ServerAliveCountMax=3')


def ssh_argv(alias,arguments):return ('/usr/bin/ssh',*SSH_OPTIONS,host(alias),shlex.join(arguments))


class Remote:
    def __init__(self,jobs,launcher_sha,output,run=subprocess.run):
        self.jobs,self.launcher_sha,self.output,self.run=jobs,launcher_sha,Path(output),run
        self.records=[];self.owner_cache={};self.job_hashes=[]
        for rank,job in enumerate(jobs):
            raw=canonical(job)+b'\n';self.job_hashes.append(hashlib.sha256(raw).hexdigest())
            write_new(self.output/('job-%d.json'%rank),raw)
        (self.output/'controls').mkdir(mode=0o700)

    def argv(self,rank,operation):
        job=self.jobs[rank]
        arguments=['/usr/bin/python3','-B',job['launcher_path']+'/remote_resident.py',operation,
            '--job-sha256',self.job_hashes[rank],'--launcher-sha256',self.launcher_sha]
        if operation!='prepare':arguments+=['--run-dir',job['peer']['run_dir']]
        return ssh_argv(job['peer']['host'],arguments)

    def call(self,rank,operation,timeout=15):
        argv=self.argv(rank,operation);record=dict(rank=rank,operation=operation,argv=list(argv))
        self.records.append(record);number=len(self.records)-1
        try:
            result=self.run(argv,input=canonical(self.jobs[rank])+b'\n' if operation=='prepare' else b'',
                capture_output=True,timeout=timeout,check=False)
            write_new(self.output/('controls/%03d.stdout'%number),result.stdout)
            write_new(self.output/('controls/%03d.stderr'%number),result.stderr)
            record.update(exitCode=result.returncode,stdoutBytes=len(result.stdout),stderrBytes=len(result.stderr))
            require(result.returncode==0 and not result.stderr and len(result.stdout)<=2*1024**2,'Remote control failed or exceeded bounds')
            record['response']=parse(result.stdout)
            return record['response']
        except BaseException as error:
            record['error']=cleanup_error_text(error)[0];raise
        finally:write_json(self.output/('controls/%03d.json'%number),record)

    def prepare(self,rank):
        record=self.call(rank,'prepare',60);job=self.jobs[rank]
        fields(record,'schema jobSHA256 rank identity promptSHA256 matrixSHA256 nativeStarted','prepared')
        require(record['schema']=='resident_remote_prepared_v1' and record['jobSHA256']==self.job_hashes[rank]
            and type(record['rank']) is int and record['rank']==rank and record['nativeStarted'] is False,'Prepared binding differs')
        exact(record['identity'],dict(nativeSHA256=job['native_sha256'],packageSHA256=job['package_sha256'],
            bundleSHA256=job['bundle_sha256'],sourceSnapshotSHA256=record['identity']['sourceSnapshotSHA256'],
            packageMembers=job['package_members'],modelPayloadVerifiedByPython=False),'Deployment identity differs')
        from solo_reference import REFERENCE_PINS
        require(record['promptSHA256']==REFERENCE_PINS['prompt.json'] and record['matrixSHA256']==hashlib.sha256(canonical(job['matrix'])+b'\n').hexdigest(),'Prepared inputs differ')
        return record

    def owner(self,rank):
        if rank not in self.owner_cache:
            value=self.call(rank,'status');require(value.get('kind')=='owner','Ready requires actual remote owner metadata')
            owner=value['record'];job=self.jobs[rank]
            fields(owner,'schema jobSHA256 rank nativeSHA256 nativePID nativePGID supervisorPID bundlePath nativeArgv nativeEnvironment','owner')
            require(owner['schema']=='resident_remote_owner_v1' and owner['jobSHA256']==self.job_hashes[rank]
                and type(owner['rank']) is int and owner['rank']==rank and owner['nativeSHA256']==job['native_sha256'],'Owner binding differs')
            require(type(owner['nativePID']) is int and owner['nativePID']>0 and owner['nativePGID']==owner['nativePID']
                and type(owner['supervisorPID']) is int and owner['supervisorPID']>0,'Native process ownership differs')
            from physical_common import native_spec
            argv,env,bundle=native_spec(job)
            exact(owner['nativeArgv'],list(argv),'Remote argv differs');exact(owner['nativeEnvironment'],env,'Remote environment differs')
            require(owner['bundlePath']==str(bundle),'Remote bundle path differs')
            self.owner_cache[rank]=owner
        return self.owner_cache[rank]

    def terminal(self,rank,deadline):
        while time.monotonic()<deadline:
            result=self.call(rank,'status',timeout=max(1,min(10,deadline-time.monotonic())))
            if result.get('kind')=='terminal':
                record=result['record'];job=self.jobs[rank]
                require(record['schema']=='resident_remote_terminal_v1' and record['jobSHA256']==self.job_hashes[rank]
                    and type(record['rank']) is int and record['rank']==rank and record['nativeSHA256']==job['native_sha256'],'Terminal binding differs')
                if rank in self.owner_cache:exact(record['owner'],self.owner_cache[rank],'Terminal owner changed')
                return record
            time.sleep(.1)
        raise TimeoutError('Remote terminal/reaping receipt unavailable')

    def retrieve(self,rank,terminal):
        target=self.output/('remote-rank-%d'%rank);target.mkdir(mode=0o700)
        job=self.jobs[rank];items=['job.json','prepared.json','terminal.json','prompt.json','matrix.json',
            'prepare-resources.jsonl','resources.jsonl']
        if 'owner' in terminal:items.append('owner.json')
        for item in terminal.get('streams',[]):
            require(item['worker']==0 and item['stream'] in ('stdin','stdout','stderr'),'Unexpected remote stream')
            items.append('native/worker-0.'+item['stream'])
        records=[]
        for name in items:
            destination=target/name;destination.parent.mkdir(exist_ok=True)
            argv=('/usr/bin/scp','-q','-o','BatchMode=yes','-o','StrictHostKeyChecking=yes','-o','ConnectTimeout=5',
                job['peer']['host']+':'+shlex.quote(job['peer']['run_dir']+'/'+name),str(destination))
            result=self.run(argv,capture_output=True,timeout=30,check=False)
            require(result.returncode==0 and not result.stdout and not result.stderr,'Remote evidence retrieval failed: '+name)
            item=snapshot(destination,160*1024**2 if name.endswith('.stdout') else 128*1024**2,keep=False,empty=True)
            records.append(dict(path=str(destination.relative_to(self.output)),sha256=item['sha256'],size_bytes=item['size_bytes']))
        exact(parse((target/'terminal.json').read_bytes()),terminal,'Retrieved terminal changed')
        require(hashlib.sha256((target/'job.json').read_bytes()).hexdigest()==self.job_hashes[rank],'Retrieved job changed')
        for item in terminal.get('streams',[]):
            require(item['worker']==0 and item['stream'] in ('stdin','stdout','stderr'),'Unexpected remote stream')
            value=snapshot(target/('native/worker-0.'+item['stream']),160*1024**2,keep=False,empty=True)
            require(value['sha256']==item['sha256'] and value['size_bytes']==item['bytes'],'Remote retained stream changed')
        for filename in ('prepare-resources.jsonl','resources.jsonl'):
            raw=snapshot(target/filename,128*1024**2,empty=terminal['status']!='completed')['raw'];lines=raw.splitlines()
            if not lines and terminal['status']!='completed':continue
            require(1<=len(lines)<=2000,'Resource sample count differs')
            for line in lines:require(len(line)<=65536,'Resource row bound');validate_local(parse(line))
        return records


class Capture:
    def __init__(self,output):
        self.output=Path(output);self.indices=[0,0];self.records=[]
        (self.output/'events').mkdir(mode=0o700)
    def __call__(self,rank,event):
        raw=snapshot(self.output/('pipes/worker-%d.stdout'%rank),160*1024**2)['raw']
        lines=raw.splitlines(keepends=True);index=self.indices[rank]
        require(index<len(lines) and lines[index].endswith(b'\n'),'Missing retained native LF record')
        line=lines[index];exact(parse(line),event,'Retained native event differs')
        name='events/rank-%d-%02d-%s.jsonl'%(rank,index,event['type']);write_new(self.output/name,line)
        value=hashlib.sha256(line).hexdigest();self.records.append(dict(path=name,sha256=value,size_bytes=len(line)))
        self.indices[rank]+=1;return value


def validate_completed_streams(output,rank,terminal):
    output=Path(output)
    require({item['stream'] for item in terminal['streams']}=={'stdin','stdout','stderr'}
        and len(terminal['streams'])==3,'Remote stream coverage differs')
    for item in terminal['streams']:
        require(item['worker']==0,'Unexpected remote stream worker')
        local=snapshot(output/('pipes/worker-%d.%s'%(rank,item['stream'])),160*1024**2,keep=False,empty=True)
        if item['stream']=='stderr':
            require(local['size_bytes']==0,'Unexpected SSH stderr')
            native=snapshot(output/('remote-rank-%d/native/worker-0.stderr'%rank),180,empty=True)
            require(native['sha256']==item['sha256'] and native['size_bytes']==item['bytes'],'Native stderr identity differs')
            exact(validate_retry_bytes(rank,native['raw']),terminal['bootstrapDiagnostics'],'Native bootstrap diagnostics differ')
        else:require(local['sha256']==item['sha256'] and local['size_bytes']==item['bytes'],'SSH/native raw stream mismatch')


def main(arguments=None):
    parser=argparse.ArgumentParser(description=__doc__,allow_abbrev=False)
    parser.add_argument('--config',type=Path,required=True);parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args(arguments);require(args.config.is_absolute() and args.output.is_absolute(),'Absolute local paths required')
    config=snapshot(args.config,16384);plan=read_plan(parse(config['raw']));output=args.output
    require(output.parent.is_dir() and not os.path.lexists(output),'New output required')
    output.mkdir(mode=0o700);write_new(output/'plan.json',config['raw'])
    pins=Pins();here=Path(__file__).parent
    manifest=snapshot(here/'manifest.json',1024**2);verify_launcher(here,manifest['sha256'],pins)
    declared=[dict(request_id=plan['cohort_id']+suffix,epoch=uuid.uuid4().hex) for suffix in SUFFIXES]
    requests=[dict(request_id=row['request_id'],phase='warmup' if i==0 else 'measured',iteration=0 if i==0 else i-1)
        for i,row in enumerate(declared)]
    jobs=make_jobs(plan,declared);remote=Remote(jobs,manifest['sha256'],output);capture=Capture(output)
    validator=RankValidator(jobs,remote.owner,capture);prepared=[];cohort=None;primary=None
    receipt=dict(schema='resident_physical_cohort_v1',status='preparing',planSHA256=config['sha256'],launcherManifestSHA256=manifest['sha256'],
        startedAtUTC=datetime.now(timezone.utc).isoformat(),primaryFailure=None,cleanupErrors=[],postflightErrors=[],measurements=[],
        remoteRetirementConfirmed=[False,False],remoteNativeNotStarted=[False,False],physicalTransferQualified=False,externalTTFTMeasured=False,
        performanceQualified=False,mtpEnabled=False,physicalTwoMachineExecutionRequested=True)
    previous=signal.getsignal(signal.SIGTERM)
    def stop(signum,frame):raise KeyboardInterrupt('Parent SIGTERM')
    signal.signal(signal.SIGTERM,stop)
    try:
        for rank in (0,1):prepared.append(remote.prepare(rank))
        require(prepared[0]['identity']['sourceSnapshotSHA256']==prepared[1]['identity']['sourceSnapshotSHA256'],'Peer source snapshots differ')
        env={key:os.environ[key] for key in ('HOME','SSH_AUTH_SOCK','LANG','LC_ALL') if key in os.environ}
        env['PATH']='/usr/bin:/bin:/usr/sbin:/sbin'
        workers=[WorkerSpec(remote.argv(rank,'run'),env,'rank',rank) for rank in (0,1)]
        # Actual resource sampling is remote, inside the pinned owning supervisor.
        # A no-op local screen would concern this client's memory, not either GPU.
        def resource_owner_gate(phase):
            require(len(prepared)==2,'Both remote resource/source preparations required')
        cohort=ResidentWorkerCohort(workers,plan['cohort_id'],declared,output/'pipes',315,
            resource_owner_gate,validator.identity,validator.numerical)
        with cohort:
            for index,request in enumerate(requests):
                value=cohort.run(request);receipt['measurements'].append(dict(request=request,measurement=value))
                write_json(output/('measurement-%d.json'%index),receipt['measurements'][-1])
        receipt['status']='completed'
    except BaseException as error:
        primary=error;receipt['status']='failed';receipt['primaryFailure']=cleanup_error_text(error)[0]
    finally:
        # Always address both remote jobs, including a partially started pair.
        if receipt['status']!='completed':
            for rank in range(len(prepared)):
                try:remote.call(rank,'cancel')
                except BaseException as error:
                    receipt['cleanupErrors'].append(dict(rank=rank,operation='cancel',error=cleanup_error_text(error)[0]))
                    if not isinstance(error,Exception) and isinstance(primary,(Exception,type(None))):primary=error
        receipt['remoteTerminals']=[None,None];receipt['retrievedFiles']=[]
        for rank in range(len(prepared)):
            try:
                terminal=remote.terminal(rank,time.monotonic()+15);receipt['remoteTerminals'][rank]=terminal
                receipt['remoteNativeNotStarted'][rank]=terminal.get('nativeNotStarted') is True
                receipt['remoteRetirementConfirmed'][rank]=(terminal['nativeLeaderReaped'] is True and terminal['ownedGroupFenceComplete'] is True)
                require(receipt['remoteRetirementConfirmed'][rank] or receipt['remoteNativeNotStarted'][rank],'Remote native retirement not established')
                if receipt['status']=='completed':
                    require(terminal['status']=='completed' and terminal['completedRequests']==4 and terminal['nativeExitCodes']==[0]
                        and terminal['outputComplete'] is True and terminal['sourceInputsUnchanged'] is True
                        and not terminal['cleanupErrors'] and not terminal['postflightErrors'],'Remote terminal failed')
                receipt['retrievedFiles']+=remote.retrieve(rank,terminal)
                if receipt['status']=='completed':validate_completed_streams(output,rank,terminal)
            except BaseException as error:
                receipt['postflightErrors'].append(dict(rank=rank,operation='remote_terminal_or_retrieval',error=cleanup_error_text(error)[0]))
                if not isinstance(error,Exception) and isinstance(primary,(Exception,type(None))):primary=error
        for name,callback in (('launcher_recheck',pins.recheck),('reference_recheck',validator.reference.recheck)):
            try:callback()
            except BaseException as error:
                receipt['postflightErrors'].append(dict(operation=name,error=cleanup_error_text(error)[0]))
                if not isinstance(error,Exception) and isinstance(primary,(Exception,type(None))):primary=error
        if cohort is not None:receipt['localSSHTransport']=cohort.evidence()
        receipt['validatedRequests']=validator.results;receipt['runtimes']=validator.runtime;receipt['rawEvents']=capture.records
        if receipt['cleanupErrors'] or receipt['postflightErrors'] or not all(receipt['remoteRetirementConfirmed']):receipt['status']='failed'
        receipt['completedAtUTC']=datetime.now(timezone.utc).isoformat();write_json(output/'receipt.json',receipt)
        signal.signal(signal.SIGTERM,previous)
    print(canonical(dict(status=receipt['status'],receipt=str(output/'receipt.json'))).decode())
    if primary is not None and not isinstance(primary,Exception):raise primary
    return 0 if receipt['status']=='completed' else 1


if __name__=='__main__':raise SystemExit(main())
