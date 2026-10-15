#!/usr/bin/env python3
"""One remotely owned rank; stdout is native JSONL only, terminal proof is a file."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import select
import signal
import sys
import time

sys.dont_write_bytecode=True
from binding_inputs import snapshot
from physical_common import (Pins, canonical, exact, parse, path, require, native_spec,
    validate_job, verify_deployment, verify_launcher, write_new, write_json)
from solo_reference import REFERENCE_PINS
from solo_resources import ResourceGate
from worker_contract import WorkerSpec, event, open_command, run_command
from worker_processes import PipeWorkers, cleanup_error_text


def control(job, operation):
    run=path(job['peer']['run_dir'])
    if operation=='cancel':
        marker=run/'cancel'
        try:write_new(marker,b'cancel\n')
        except FileExistsError:
            require(marker.is_file() and not marker.is_symlink(),'Cancel marker differs')
        return dict(cancelRequested=True,remoteRetirementConfirmed=False)
    for name in ('terminal.json','owner.json'):
        candidate=run/name
        if candidate.exists():return dict(kind=name[:-5],record=parse(snapshot(candidate,2*1024**2)['raw']))
    return dict(kind='pending',remoteRetirementConfirmed=False)


def serve(job, spec, run, gate, pins, input_fd=0, output_fd=1, timeout=315):
    """Private execution seam: CLI first verifies native argv, package and inputs.

    Tests inject a fabricated Python child here. No SSH exit is treated as a
    native exit: this function owns native Popen/waitpid and process-group fences.
    """
    run=Path(run);job_sha=hashlib.sha256(canonical(job)+b'\n').hexdigest()
    receipt=dict(schema='resident_remote_terminal_v1',jobSHA256=job_sha,rank=job['rank'],status='starting',
        nativeSHA256=job['native_sha256'],completedRequests=0,primaryFailure=None,postflightErrors=[],
        nativeLeaderReaped=False,ownedGroupFenceComplete=False,descendantReapingIndependentlyProven=False,
        sourceInputsUnchanged=False,physicalTransferQualified=False)
    pipes=None;old_handlers={};pending=bytearray();started=time.monotonic();opened=job['opened']
    input_blocking=os.get_blocking(input_fd);output_blocking=os.get_blocking(output_fd)
    def guard(phase):
        require(not (run/'cancel').exists(),'Owned remote cancellation requested')
        require(time.monotonic()-started<timeout,'Remote supervisor deadline expired')
        gate(phase)
    def interrupted(number,frame):raise SystemExit(128+number)
    def checked(phase):
        guard(phase)
        if pipes is not None:pipes.check()
    def read_command():
        while b'\n' not in pending:
            checked('control-wait')
            if not select.select([input_fd],[],[],.05)[0]:continue
            block=os.read(input_fd,4097-len(pending))
            require(block,'Control input ended before explicit shutdown')
            pending.extend(block);require(len(pending)<=4097,'Control line exceeds 4 KiB')
        raw,remaining=pending.split(b'\n',1);pending.clear();pending.extend(remaining)
        require(raw and len(raw)<=4096 and not pending,'Pipelined/invalid control input')
        return parse(raw)
    def forward(raw):
        remaining=memoryview(raw+b'\n')
        while remaining:
            checked('forward')
            if not select.select([],[output_fd],[],.05)[1]:continue
            count=os.write(output_fd,remaining);require(count>0,'SSH output did not advance');remaining=remaining[count:]
    def collect(kind,command):
        def validate(index,raw):
            value=event(raw,spec,kind,command)
            forward(raw)
            return value
        return pipes.collect('native-'+kind,validate)[0]
    primary=None
    try:
        for number in (signal.SIGHUP,signal.SIGTERM,signal.SIGINT):
            old_handlers[number]=signal.getsignal(number);signal.signal(number,interrupted)
        os.set_blocking(input_fd,False);os.set_blocking(output_fd,False)
        guard('prelaunch')
        first=read_command();exact(first,opened,'Open command differs from predeclared job')
        pipes=PipeWorkers((spec,),run/'native',timeout,guard)
        pipes.start()
        owner=dict(schema='resident_remote_owner_v1',jobSHA256=job_sha,rank=job['rank'],nativeSHA256=job['native_sha256'],
            nativePID=pipes.children[0].pid,nativePGID=pipes.children[0].pid,supervisorPID=os.getpid(),
            bundlePath=str(Path(spec.argv[0]).parent),nativeArgv=list(spec.argv),nativeEnvironment=dict(spec.env))
        write_json(run/'owner.json',owner);receipt['owner']=owner
        pipes.send(opened);collect('ready',opened)
        for ordinal in range(4):
            declared=opened['requests'][ordinal]
            requested=dict(request_id=declared['request_id'],phase='warmup' if ordinal==0 else 'measured',iteration=0 if ordinal==0 else ordinal-1)
            expected=run_command(opened,ordinal,requested)
            command=read_command();exact(command,expected,'Run command differs')
            pipes.gate('before-request-%d'%ordinal);pipes.send(command);collect('result',command)
            receipt['completedRequests']+=1
        collect('released',command)
        shutdown=dict(schema=opened['schema'],type='shutdown',cohort_id=opened['cohort_id'],sequence=5)
        command=read_command();exact(command,shutdown,'Expected explicit shutdown')
        pipes.send(command);collect('stopped',command);pipes.finish()
        receipt['status']='completed'
    except BaseException as error:
        primary=error;receipt['status']='failed';receipt['primaryFailure']=cleanup_error_text(error)[0]
    finally:
        if pipes is not None:
            try:pipes.close(kill=receipt['status']!='completed')
            except BaseException as error:
                receipt['postflightErrors'].append(dict(operation='native_cleanup',error=cleanup_error_text(error)[0]))
                if not isinstance(error,Exception) and isinstance(primary,(Exception,type(None))):primary=error
            receipt['nativeLeaderReaped']=bool(pipes.children) and all(p.returncode is not None for p in pipes.children)
            receipt['ownedGroupFenceComplete']=bool(pipes.children) and all(p.pid in pipes._fenced_groups for p in pipes.children)
            receipt['nativeExitCodes']=[p.returncode for p in pipes.children]
            receipt['outputComplete']=pipes.complete_output
            receipt['cleanupErrors']=list(pipes.cleanup_errors)
            try:receipt['streams']=pipes.retained_streams()
            except BaseException as error:
                receipt['postflightErrors'].append(dict(operation='retained_stream_hashes',error=cleanup_error_text(error)[0]))
                if not isinstance(error,Exception) and isinstance(primary,(Exception,type(None))):primary=error
        for name,callback in (('source_input_recheck',pins.recheck),('resource_postflight',lambda:gate('postflight'))):
            try:
                callback()
                if name=='source_input_recheck':receipt['sourceInputsUnchanged']=True
            except BaseException as error:
                receipt['postflightErrors'].append(dict(operation=name,error=cleanup_error_text(error)[0]))
                if not isinstance(error,Exception) and isinstance(primary,(Exception,type(None))):primary=error
        if receipt['postflightErrors'] or receipt.get('cleanupErrors') or not receipt['nativeLeaderReaped'] or not receipt['ownedGroupFenceComplete']:
            receipt['status']='failed'
        write_json(run/'terminal.json',receipt)
        os.set_blocking(input_fd,input_blocking);os.set_blocking(output_fd,output_blocking)
        for number,handler in old_handlers.items():signal.signal(number,handler)
    if primary is not None and not isinstance(primary,Exception):raise primary
    return 0 if receipt['status']=='completed' else 1


def main():
    parser=argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument('operation',choices=('prepare','run','status','cancel'))
    parser.add_argument('--job-sha256',required=True)
    parser.add_argument('--launcher-sha256',required=True)
    parser.add_argument('--run-dir')
    args=parser.parse_args();pins=Pins();here=Path(__file__).parent
    verify_launcher(here,args.launcher_sha256,pins)
    if args.operation=='prepare':
        raw=sys.stdin.buffer.read(16385);require(0<len(raw)<=16384,'Job exceeds bound')
        require(hashlib.sha256(raw).hexdigest()==args.job_sha256,'Job raw hash differs')
        job=validate_job(parse(raw));require(raw==canonical(job)+b'\n','Job must be exact canonical JSONL')
        require(str(here)==job['launcher_path'],'Staged launcher path differs')
        run=path(job['peer']['run_dir']);require(run.parent.resolve()==run.parent,'Run parent contains symlinks')
        run.mkdir(mode=0o700);write_new(run/'job.json',raw)
        log=(run/'prepare-resources.jsonl').open('xb',buffering=0)
        try:
            gate=ResourceGate(lambda row:log.write(canonical(row)+b'\n'))
            gate('prelaunch');identity=verify_deployment(job,pins)
            prompt=pins.read(here/'reference/prompt.json',65536,REFERENCE_PINS['prompt.json'])['raw']
            write_new(run/'prompt.json',prompt);write_new(run/'matrix.json',canonical(job['matrix'])+b'\n')
            pins.recheck();gate('postflight')
        finally:log.close()
        record=dict(schema='resident_remote_prepared_v1',jobSHA256=args.job_sha256,rank=job['rank'],identity=identity,
            promptSHA256=REFERENCE_PINS['prompt.json'],matrixSHA256=hashlib.sha256((run/'matrix.json').read_bytes()).hexdigest(),nativeStarted=False)
        write_json(run/'prepared.json',record);sys.stdout.buffer.write(canonical(record)+b'\n');return 0
    require(args.run_dir is not None,'Explicit run directory required')
    run=path(args.run_dir);raw=pins.read(run/'job.json',16384,args.job_sha256)['raw'];job=validate_job(parse(raw))
    require(str(run)==job['peer']['run_dir'] and str(here)==job['launcher_path'],'Remote run binding differs')
    if args.operation in ('status','cancel'):
        sys.stdout.buffer.write(canonical(control(job,args.operation))+b'\n');return 0
    write_new(run/'run-started',b'started\n')
    log=(run/'resources.jsonl').open('xb',buffering=0)
    native_scope_entered=False
    try:
        gate=ResourceGate(lambda row:log.write(canonical(row)+b'\n'))
        gate('prelaunch');verify_deployment(job,pins)
        pins.read(run/'prompt.json',65536,REFERENCE_PINS['prompt.json'])
        matrix=pins.read(run/'matrix.json',4096)['raw'];require(matrix==canonical(job['matrix'])+b'\n','Matrix changed')
        argv,env,bundle=native_spec(job);os.chdir(bundle)
        native_scope_entered=True
        return serve(job,WorkerSpec(argv,env,'rank',job['rank']),run,gate,pins)
    except BaseException as error:
        if not native_scope_entered:
            write_json(run/'terminal.json',dict(schema='resident_remote_terminal_v1',jobSHA256=args.job_sha256,
                rank=job['rank'],nativeSHA256=job['native_sha256'],status='failed',nativeNotStarted=True,
                nativeLeaderReaped=False,ownedGroupFenceComplete=False,descendantReapingIndependentlyProven=False,
                completedRequests=0,nativeExitCodes=[],sourceInputsUnchanged=False,cleanupErrors=[],postflightErrors=[],
                primaryFailure=cleanup_error_text(error)[0]))
        raise
    finally:log.close()


if __name__=='__main__':raise SystemExit(main())
