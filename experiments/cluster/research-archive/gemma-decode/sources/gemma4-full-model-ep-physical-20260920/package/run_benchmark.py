"""One bounded native cohort. Canonical device lock is inherited across exec."""
import argparse
import json
import os
from pathlib import Path
import signal
import time
from benchmark_package import digest, verify
from binding_common import parse, require
from gemma_inputs import PRODUCT, REMOTE, write_json
from jaccl_startup_stderr import JacclStartupProgress
from mtp_journal import device_directory, observe, require_empty
from reference_resources import ResourceGate, read_command
from target_processes import observe as processes
from worker_contract import WorkerSpec
from worker_processes import PipeWorkers, cleanup_error_text

def main():
    parser=argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument('--package-sha256',required=True)
    parser.add_argument('--job',type=Path,required=True)
    parser.add_argument('--job-sha256',required=True)
    args=parser.parse_args(); os.umask(0o077)
    started=time.monotonic(); deadline=started+315
    require(args.job.parent.parent==REMOTE/'runs' and args.job.name=='job.json','Job path')
    run=args.job.parent
    require(run.resolve()==run and digest(args.job)==args.job_sha256,'Job identity')
    package=verify(args.package_sha256)
    job=parse(args.job.read_bytes())
    require(job['schema']=='gemma4_full_expert_correctness_job_v1' and job['mode'] in ('full','expert0','expert1'), 'Job schema/mode')
    require(job['timeoutSeconds']==300,'Native lifetime must fit parent fence')
    require(job['outputDirectory']==str(run/'sidecars'),'Output path')
    require(job['metadataDirectory']==str(REMOTE/'metadata'),'Metadata path')
    require(job['modelDirectory']=='/Users/developer/DarkbloomDev/models/Gemma4-26B','Model path')
    require(job['buildIdentitySHA256']==digest(REMOTE/'bundle'/PRODUCT),'Native/job identity')
    require(job['rankBuildSHA256']==[job['buildIdentitySHA256']]*2,'First EP pair requires the same bound actual product')
    require(job['promptFile']==str(REMOTE/'prompt.ids.json')
            and job['promptFileSHA256']==digest(REMOTE/'prompt.ids.json'),'Bound P32 prompt')
    record={'schema':'gemma4_full_expert_terminal_v1','status':'failed','mode':job['mode'],
            'packageSHA256':args.package_sha256,'jobSHA256':args.job_sha256,
            'encryptedRDMAEstablished':False,'externalHTTPTTFTMeasured':False,
            'primaryFailure':None,'cleanupErrors':[]}
    pipes=None; before=None
    resources=(run/'resources.jsonl').open('xb',buffering=0)
    gate=ResourceGate(lambda row:PipeWorkers._write_all(resources,json.dumps(row,sort_keys=True).encode()+b'\n'))
    def guard(phase):
        require(time.monotonic()<deadline,'Original parent deadline expired')
        cancellation=run/'cancellation.json'
        if cancellation.exists():
            require(not cancellation.is_symlink() and cancellation.stat().st_size<=4096,'Unsafe cancellation record')
            value=parse(cancellation.read_bytes())
            require(value=={'schema':'gemma4_full_expert_cancellation_v1','jobSHA256':args.job_sha256},
                    'Cancellation identity differs')
            raise RuntimeError('Matching peer failed; cancel this owned native group')
        gate(phase)
    def interrupt(number,_): raise SystemExit(128+number)
    previous={number:signal.signal(number,interrupt) for number in (signal.SIGHUP,signal.SIGINT,signal.SIGTERM)}
    try:
        guard('prelaunch')
        memory=int(read_command(['/usr/sbin/sysctl','-n','hw.memsize']).strip())
        require(memory==(24 if job['mode']=='expert0' else 48)*1024**3,'Wrong physical host role')
        require(not processes(deadline)['prohibited'],'Existing native/owner process')
        before=observe(device_directory());require_empty(before)
        write_json(run/'journal-before.json',before)
        env=dict(PATH='/usr/bin:/bin:/usr/sbin:/sbin',HOME=str(Path.home()),LANG='C',
                 DARKBLOOM_CBV2_ATTN_QUERY_BLOCK='128',DARKBLOOM_BF16_WEIGHTS='1',MLX_ENABLE_TF32='1')
        if job['mode']!='full':
            env.update(JACCL_RANK='0' if job['mode']=='expert0' else '1',
                       JACCL_IBV_DEVICES=str(REMOTE/'matrix.json'),JACCL_COORDINATOR='192.0.2.250:51361')
        binary=REMOTE/'bundle'/PRODUCT;s=binary.lstat()
        launch=dict(binary=str(binary),job=str(args.job),environment=env,
                    binaryIdentity=[s.st_dev,s.st_ino,s.st_mode,s.st_size,s.st_mtime_ns,s.st_ctime_ns],
                    jobSHA256=args.job_sha256)
        write_json(run/'launch.json',launch)
        spec=WorkerSpec(('/usr/bin/python3','-B',str(REMOTE/'native_gate.py'),'--launch',str(run/'launch.json'),
                         '--launch-sha256',digest(run/'launch.json')),
                        dict(PATH=env['PATH'],HOME=env['HOME'],LANG='C'),'solo',None)
        remaining=int(deadline-time.monotonic())
        require(remaining>=301,'Insufficient time for native lifetime and cleanup')
        stderr=JacclStartupProgress() if job['mode']=='expert1' else None
        pipes=PipeWorkers((spec,),run/'native',remaining,guard,stderr_policy=stderr);pipes.start()
        record['nativePIDs']=[child.pid for child in pipes.children]
        write_json(run/'owner.json',dict(parentPID=os.getpid(),nativePIDs=record['nativePIDs'],
                                        nativePGIDs=record['nativePIDs'],deadlineMonotonic=deadline))
        def result(_,raw):
            require(len(raw)<=1_048_576,'Native final JSON exceeds fixed report bound')
            value=parse(raw)
            require(isinstance(value,dict) and value.get('schema')=='gemma4_full_expert_result_v1'
                    and value.get('mode')==job['mode'],'Native result schema/role')
            # Numerical/timing acceptance is performed separately against the
            # exact description and both rank outputs, after process retirement.
            return value
        record['result']=pipes.collect('benchmark',result)[0]
        pipes.finish()
        if stderr is not None:record['startupStderr']=stderr.summary()
        record['status']='completed'
    except BaseException as error:
        record['primaryFailure']=cleanup_error_text(error)[0]
    finally:
        if pipes is not None:
            try:pipes.close(kill=record['status']!='completed')
            except BaseException as error:record['cleanupErrors'].append(cleanup_error_text(error)[0])
            record.update(exitCodes=[child.returncode for child in pipes.children],
                          outputComplete=pipes.complete_output,cleanupErrors=record['cleanupErrors']+pipes.cleanup_errors)
            absent=[]
            for child in pipes.children:
                try:os.killpg(child.pid,0);absent.append(False)
                except ProcessLookupError:absent.append(True)
                except BaseException as error:
                    absent.append(False);record['cleanupErrors'].append(cleanup_error_text(error)[0])
            record['groupsAbsent']=bool(absent) and all(absent)
            if record['exitCodes']!=[0] or not record['outputComplete'] or not record['groupsAbsent']:
                record['status']='failed'
        try:
            after=observe(device_directory());require_empty(after,before)
            write_json(run/'journal-after.json',after)
            require(not processes(time.monotonic()+4)['prohibited'],'Native/owner remains')
            record['journalEmptyAndProcessesRetired']=True
            gate('postflight')
            verify(args.package_sha256)
            require(digest(args.job)==args.job_sha256,'Job changed')
        except BaseException as error:record['cleanupErrors'].append(cleanup_error_text(error)[0])
        if record['cleanupErrors'] or time.monotonic()>=deadline:record['status']='failed'
        record['elapsedSeconds']=time.monotonic()-started
        write_json(run/'terminal.json',record);resources.close()
        for number,handler in previous.items():signal.signal(number,handler)
    print(json.dumps({'status':record['status'],'mode':job['mode'],'run':str(run),
                      'terminalSHA256':digest(run/'terminal.json')}),flush=True)
    return 0 if record['status']=='completed' else 1

if __name__=='__main__':raise SystemExit(main())
