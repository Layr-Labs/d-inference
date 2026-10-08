"""Root-authorized one-host execution. No automatic retry or next request."""
import argparse
import os
from pathlib import Path
import platform
import signal
import sys
import time
from binding_common import canonical, parse, require, same, sha
from binding_inputs import snapshot
from gemma_inputs import REMOTE, PRODUCT, MODES, Pins, verify_package, job_for, write_json, write_new
from gemma_supervision import serve
from mtp_journal import device_directory, observe as journal, require_empty
from reference_resources import ResourceGate, read_command
from target_processes import observe as processes
from worker_contract import WorkerSpec
from worker_processes import PipeWorkers, cleanup_error_text


def host_preflight(mode,deadline):
    required=24 if mode=='stage0' else 48
    memory=read_command(['/usr/sbin/sysctl','-n','hw.memsize'])
    same(memory.strip(),str(required*1024**3),'Actual host memory role')
    inventory=processes(deadline);require(not inventory['prohibited'],'A native/owner is already live')
    lease=journal(device_directory());require_empty(lease)
    return dict(physicalMemoryBytes=int(memory),processes=inventory,journal=lease)


def model_metadata(model,root,rows):
    require(model.is_absolute() and model.resolve()==model and model.is_dir(),'Canonical existing model required')
    for name in ('config.json','manifest.json','model.safetensors.index.json'):
        item=snapshot(model/name,2*1024**2);same(item['sha256'],rows['metadata/'+name]['sha256'],'Actual model metadata')
    manifest=parse((root/'metadata/manifest.json').read_bytes());require(len(manifest['files'])==10,'Model file coverage')
    observed=[]
    for row in manifest['files']:
        name=row['path'];require(Path(name).name==name,'Model member name');p=model/name;s=p.lstat()
        import stat
        require(stat.S_ISREG(s.st_mode) and s.st_uid==os.geteuid() and s.st_nlink==1 and s.st_size==row['size_bytes'],
                'Model file availability/declared size differs')
        observed.append(dict(path=name,bytes=s.st_size,device=s.st_dev,inode=s.st_ino,mtimeNS=s.st_mtime_ns))
    return dict(files=observed,fullPayloadHashPerformed=False,selectedPayloadVerificationOwnedByNative=True)


def main():
    p=argparse.ArgumentParser(allow_abbrev=False);p.add_argument('--package-sha256',required=True)
    p.add_argument('--mode',choices=MODES,required=True);p.add_argument('--attempt',type=int,default=1)
    p.add_argument('--observe-only',action='store_true');a=p.parse_args()
    require(Path(__file__).resolve().parent==REMOTE,'Wrong fresh installed root')
    require(platform.system()=='Darwin' and platform.machine()=='arm64','Apple Silicon required')
    require(1<=a.attempt<=9,'Bounded explicit attempt');os.umask(0o077)
    started=time.monotonic();deadline=started+315;run=None;log=None;entered=False
    def check():require(time.monotonic()<deadline,'Original parent deadline exhausted')
    def interrupted(n,_):raise SystemExit(128+n)
    prior={n:signal.getsignal(n) for n in (signal.SIGHUP,signal.SIGINT,signal.SIGTERM)}
    for n in prior:signal.signal(n,interrupted)
    try:
        pins=Pins(check);binding,expected,template,rows=verify_package(REMOTE,a.package_sha256,pins)
        if a.observe_only:
            samples=[];ResourceGate(samples.append)('prelaunch')
            observation=host_preflight(a.mode,deadline)
            observation['resources']=samples;observation['mode']=a.mode;observation['packageSHA256']=a.package_sha256
            print(canonical(observation).decode(),flush=True);return 0
        runs=REMOTE/'runs';runs.mkdir(mode=0o700,exist_ok=True)
        require(runs.resolve()==runs and runs.stat().st_uid==os.geteuid() and runs.stat().st_mode&0o077==0,'Unsafe runs directory')
        run=runs/f'{a.mode}-{a.attempt}';run.mkdir(mode=0o700)
        write_json(run/'input-binding.json',dict(packageSHA256=a.package_sha256,binding=binding,mode=a.mode,attempt=a.attempt))
        log=os.fdopen(os.open(run/'resources.jsonl',os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600),'wb',buffering=0)
        gate=ResourceGate(lambda row:PipeWorkers._write_all(log,canonical(row)+b'\n'));gate('prelaunch')
        before=host_preflight(a.mode,deadline);write_json(run/'preflight.json',before)
        write_json(run/'model-metadata.json',model_metadata(Path(binding['modelDirectory']),REMOTE,rows))
        job=job_for(template,a.mode,a.attempt);write_json(run/'job.json',job)
        env=dict(PATH='/usr/bin:/bin:/usr/sbin:/sbin',HOME=str(Path.home()),LANG='C',
            DARKBLOOM_CBV2_ATTN_QUERY_BLOCK='128',DARKBLOOM_BF16_WEIGHTS='1',MLX_ENABLE_TF32='1')
        if a.mode!='full':env.update(JACCL_RANK='0' if a.mode=='stage0' else '1',
            JACCL_IBV_DEVICES=str(REMOTE/'matrix.json'),JACCL_COORDINATOR='169.254.70.46:51361')
        binary=REMOTE/'bundle'/PRODUCT;s=binary.lstat()
        launch=dict(binary=str(binary),job=str(run/'job.json'),environment=env,
            binaryIdentity=[s.st_dev,s.st_ino,s.st_mode,s.st_size,s.st_mtime_ns,s.st_ctime_ns],jobSHA256=sha(canonical(job)+b'\n'))
        write_json(run/'launch.json',launch);pins.recheck()
        spec=WorkerSpec(('/usr/bin/python3','-B',str(REMOTE/'native_gate.py'),'--launch',str(run/'launch.json'),
            '--launch-sha256',sha(canonical(launch)+b'\n')),dict(PATH=env['PATH'],HOME=env['HOME'],LANG='C'),'solo',None)
        def postflight():
            after=journal(device_directory());write_json(run/'journal-postflight.json',after);require_empty(after,before['journal'])
            after_processes=processes(deadline);write_json(run/'processes-postflight.json',after_processes)
            require(not after_processes['prohibited'],'Known owner/native remains')
            acquired=parse((run/'gate.json').read_bytes())
            for k in ('path','directoryDevice','directoryInode','fileDevice','fileInode'):same(acquired[k],before['journal'][k],'Gate identity')
            require(acquired['exclusiveLockHeld'] is True and acquired['journalMutationPerformed'] is False,'Gate evidence')
            return dict(journal=after,processes=after_processes,gate=acquired)
        entered=True;record=serve(spec,run,started,gate,pins,postflight,a.mode,expected)
        print(canonical(dict(mode=a.mode,status=record['status'],terminalSHA256=sha((run/'terminal.json').read_bytes()))).decode(),flush=True)
        return 0 if record['status']=='completed' else 1
    except BaseException as error:
        if run is not None and not entered:
            write_json(run/'terminal.json',dict(schema='gemma_short_native_terminal_v1',mode=a.mode,status='failed',
                nativeLaunchAttempted=False,primaryFailure=cleanup_error_text(error)[0],journalMutationPerformed=False))
        raise
    finally:
        if log is not None:log.close()
        for n,handler in prior.items():signal.signal(n,handler)


if __name__=='__main__':raise SystemExit(main())
