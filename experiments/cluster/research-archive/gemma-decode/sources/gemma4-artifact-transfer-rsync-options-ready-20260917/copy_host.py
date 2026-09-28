"""One root-selected host; strict trust, bounded receiver, verified final rename."""
import argparse
import base64
import contextlib
import io
import json
import os
from pathlib import Path
import shlex
import signal
import subprocess
import time
from artifact import BASE,PREPARATION,STAGE,FINAL,MANIFEST,PAYLOAD,digest,record,recheck,manifest
from binding_common import require,same
from owned_process import invoke_controller
from source_guard import check_sources

HOSTS={'darkbloom-24':('172.16.40.199','192.0.2.250',24),
       'darkbloom-48':('172.16.40.240','192.0.2.223',48)}
SOURCE_NAMES=('artifact.py','artifact-manifest.json','binding_common.py','lease_gate.py','mtp_journal.py','target_processes.py',
              'owned_process.py','rsync_exec.py','receive_rsync.py','remote_control.py','source_guard.py','source-pins.json')

def ssh(address,alias):
    trust=json.loads((BASE/'trust.json').read_bytes())
    same(digest(Path(trust['path']).read_bytes()),trust['sha256'],'Pinned known hosts')
    return ['/usr/bin/ssh','-F','/dev/null','-T','-S','none','-o','BatchMode=yes','-o','ConnectTimeout=5',
        '-o','IdentitiesOnly=yes','-o','StrictHostKeyChecking=yes','-o','UserKnownHostsFile='+trust['path'],
        '-o','HostKeyAlias='+alias,'-i',trust['key'],'developer@'+address]

def remote(prefix,argv,output,name,seconds,stdin=None):
    started=time.monotonic();out=b'';err=b'';receipt=dict(timeoutSeconds=seconds)
    try:
        value=subprocess.run(prefix+[shlex.join(argv)],input=stdin,capture_output=True,timeout=seconds)
        out,err=value.stdout,value.stderr;receipt['exitCode']=value.returncode
        require(len(out)+len(err)<=131072,'Bounded remote metadata output')
    except subprocess.TimeoutExpired as error:
        out,err=error.stdout or b'',error.stderr or b'';receipt['timedOut']=True;raise
    except BaseException as error:receipt['failure']=type(error).__name__+': '+str(error)[:1024];raise
    finally:
        (output/(name+'.stdout')).write_bytes(out[:131072]);(output/(name+'.stderr')).write_bytes(err[:131072])
        receipt.update(elapsedSeconds=time.monotonic()-started,stdoutSHA256=digest(out),stderrSHA256=digest(err),stdoutBytes=len(out),stderrBytes=len(err))
        record(output/(name+'.json'),receipt)
    return value

class LaunchReceipt(dict):
    def __init__(self,output):super().__init__();self.output=output
    def update(self,*args,**kwargs):
        super().update(*args,**kwargs)
        if 'pid' in self and not (self.output/'rsync-launched.json').exists():
            try:record(self.output/'rsync-launched.json',dict(self,parentPID=os.getpid(),startedUnix=time.time()))
            except BaseException as error:self['launchReceiptError']=type(error).__name__+': '+str(error)[:1024]

def main():
    p=argparse.ArgumentParser(allow_abbrev=False);p.add_argument('--host',choices=HOSTS,required=True)
    p.add_argument('--verified',required=True,type=Path);p.add_argument('--receipt-sha256',required=True);p.add_argument('--output',required=True,type=Path);a=p.parse_args()
    source_pins=check_sources()
    require(a.output.is_absolute() and a.output.parent.resolve()==a.output.parent,'Fresh canonical per-host output')
    a.output.mkdir(mode=0o700);os.umask(0o077)
    raw=(a.verified/'receipt.json').read_bytes();same(digest(raw),a.receipt_sha256,'Actual local verification receipt')
    verified=json.loads(raw);require(verified['status']=='passed' and verified['staging']['wholePayloadVerified'] is True,'Local full verification must pass first')
    stage=Path(verified['stageDirectory']);same(stage,a.verified/'model','Owned local staging');recheck(stage,verified['staging'])
    manifest_raw,rows=manifest();same((stage/'manifest.json').read_bytes(),manifest_raw,'Exact staged manifest')
    wanted='\n'.join([r['path'] for r in rows]+['manifest.json'])+'\n';same((a.verified/'files.txt').read_text(),wanted,'Exact eleven-file rsync list')
    lan,tail,gib=HOSTS[a.host];selected=None;result=dict(host=a.host,status='started',localVerificationSHA256=a.receipt_sha256,modelExecuted=False,sourcePinsSHA256=source_pins)
    original={n:signal.getsignal(n) for n in (signal.SIGHUP,signal.SIGINT,signal.SIGTERM)}
    def interrupted(n,_):raise SystemExit(128+n)
    for n in original:signal.signal(n,interrupted)
    try:
        probe="import os,json;from pathlib import Path;p=Path('/Users/developer/DarkbloomDev/models');s=os.statvfs(p);print(json.dumps(dict(availableBytes=s.f_bavail*s.f_frsize,finalExists=os.path.lexists(str(p/'Gemma4-26B')),preparationExists=os.path.lexists('/Users/developer/DarkbloomDev/gemma4-model-preparation-2-20260917'))))"
        for label,address in [('lan',lan),('tailscale',tail)]:
            prefix=ssh(address,tail)
            try:value=remote(prefix,['/usr/bin/python3','-B','-c',probe],a.output,'probe-'+label,10)
            except subprocess.TimeoutExpired as error:
                record(a.output/('probe-'+label+'-timeout.json'),dict(timeout=True));continue
            if value.returncode!=0:continue
            require(not value.stderr,'Probe stderr');observation=json.loads(value.stdout)
            require(not observation['finalExists'] and not observation['preparationExists'],'Remote target already exists; no retry')
            require(observation['availableBytes']>=PAYLOAD+16*1024**3,'Remote actual disk headroom')
            selected=prefix;result.update(address=address,transport=label,hostKeyAlias=tail,preflight=observation);break
        require(selected is not None,'Both strict-key routes failed before mutation')
        payload=dict(host=a.host,physicalMemoryBytes=gib*1024**3,files={})
        for name in SOURCE_NAMES:
            data=(BASE/('receiver-source-pins.json' if name=='source-pins.json' else name)).read_bytes()
            payload['files'][name]=dict(bytes=len(data),sha256=digest(data),base64=base64.b64encode(data).decode())
        installed=remote(selected,['/usr/bin/python3','-B','-c',(BASE/'install_receiver.py').read_text()],a.output,'prepare',20,
            stdin=json.dumps(payload,separators=(',',':')).encode())
        require(installed.returncode==0 and not installed.stderr,'Fresh receiver preparation failed')
        result['preparation']=json.loads(installed.stdout)
        same(result['preparation']['sourceFiles'],{name:{key:row[key] for key in ('bytes','sha256')} for name,row in payload['files'].items()},'Installed receiver source pins')
        receiver=shlex.join(['/usr/bin/python3','-B',str(PREPARATION/'receive_rsync.py')])
        # -e receives only SSH options; rsync appends the separately bound user/host.
        ssh_options=selected[:-1]
        command=['/usr/bin/rsync','-rt','--partial','--files-from='+str(a.verified/'files.txt'),'--timeout=60','--stats',
                 '--rsync-path='+receiver,'-e',shlex.join(ssh_options),str(stage)+'/',selected[-1]+':'+str(STAGE)+'/']
        command=['/usr/bin/python3','-B',str(BASE/'bounded_rsync.py')]+command
        origin=time.monotonic();result['copy']=LaunchReceipt(a.output);copy_error=None
        try:
            with (a.output/'rsync.stdout').open('xb') as out,(a.output/'rsync.stderr').open('xb') as err:
                with contextlib.redirect_stdout(io.StringIO()) as observation:
                    invoke_controller(command,out,err,result['copy'],timeout=900)
                result['copy']['launchObservation']=observation.getvalue()
            require(result['copy'].get('exitCode')==0 and result['copy'].get('reaped') and result['copy'].get('groupAbsent'),'Local rsync did not retire successfully')
            require('launchReceiptError' not in result['copy'],'Local sender launch receipt failed')
        except BaseException as error:copy_error=error
        finally:
            result['receiverStatus']=None;index=0
            # Never signal a discovered remote PID. The actual receiver has its
            # own kernel alarm; retain the slot until its group/lease are absent.
            while time.monotonic()<origin+910:
                try:
                    value=remote(selected,['/usr/bin/python3','-B',str(PREPARATION/'remote_control.py'),'status'],a.output,'receiver-status-'+str(index),min(10,origin+910-time.monotonic()))
                    if value.returncode==0 and not value.stderr:
                        result['receiverStatus']=json.loads(value.stdout)
                        if result['receiverStatus']['groupAbsent'] and result['receiverStatus']['journalEmptyAndUnlocked'] and result['receiverStatus']['receiverTerminal'] is not None:break
                except BaseException as error:
                    result.setdefault('cleanupErrors',[]).append(type(error).__name__+': '+str(error)[:1024])
                index+=1
                try:time.sleep(min(1,max(0,origin+910-time.monotonic())))
                except BaseException as error:
                    if copy_error is None:copy_error=error
            require(result['receiverStatus'] and result['receiverStatus']['groupAbsent'] and result['receiverStatus']['journalEmptyAndUnlocked'],'Remote bulk receiver retirement unproven')
        if copy_error is not None:raise copy_error
        require(result['receiverStatus']['receiverTerminal'] and result['receiverStatus']['receiverTerminal']['status']=='passed','Receiver terminal not successful')
        recheck(stage,verified['staging'])
        value=remote(selected,['/usr/bin/python3','-B',str(PREPARATION/'remote_control.py'),'finalize'],a.output,'verification',330)
        require(value.returncode==0 and not value.stderr,'Full remote verification/promotion failed')
        result['verification']=json.loads(value.stdout);same(result['verification']['status'],'passed','Remote promotion')
        require(result['verification']['verification']['wholePayloadVerified'] and result['verification']['postflight']['journalEmptyAndUnlocked'],'Final verification/lease')
        same(result['verification']['receiverTerminalSHA256'],result['receiverStatus']['receiverTerminalSHA256'],'Receiver/final verification receipt join')
        same(result['verification']['finalDirectory'],str(FINAL),'Final model path');recheck(stage,verified['staging'])
        same(check_sources(),source_pins,'Copy source postflight');result['status']='passed'
    except BaseException as error:result['status']='failed';result['failure']=type(error).__name__+': '+str(error)[:2048];raise
    finally:
        record(a.output/'receipt.json',result)
        for n,handler in original.items():signal.signal(n,handler)
    print(json.dumps(dict(host=a.host,status='passed',receipt=str(a.output/'receipt.json'))))
if __name__=='__main__':main()
