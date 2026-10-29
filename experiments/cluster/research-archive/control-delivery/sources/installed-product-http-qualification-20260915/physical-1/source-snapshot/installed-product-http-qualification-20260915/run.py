"""One real installed distributed session and one external authenticated request."""
from pathlib import Path
import argparse, base64, hashlib, json, os, shlex, subprocess, threading, time
import urllib.request
from guards import AliasLease, Monitor, SSH, REMOTE
from lease_source import LEASE
from physical_io import line_until, fetch_token, postflight, discovery

BASE=Path(__file__).resolve().parent
ROOT=BASE.parent

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--attempt',required=True,type=int)
    parser.add_argument('--prompt-file',required=True,type=Path)
    parser.add_argument('--client',required=True,type=Path)
    args=parser.parse_args()
    assert 1<=args.attempt<=99
    output=BASE/('physical-'+str(args.attempt));output.mkdir(mode=0o700)
    remote_run=REMOTE+'/qualification/attempt'+str(args.attempt)
    record={'schema':'installed_distributed_http_attempt_v1','startedUnix':time.time(),
            'representativePerformanceQualified':False,'openRouterQualified':False,
            'numericalReferenceCompared':False,'requestCount':1}
    codefiles=sorted(BASE.glob('*.py'))+sorted(args.client.parent.glob('*.py'))+[args.prompt_file]
    pins={str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in codefiles}
    (output/'input-pins.json').write_text(json.dumps(pins,indent=2)+'\n')
    started=time.monotonic();product_started=started;monitors=[];lease=None;supervisor=None;watcher=None
    stop_watch=threading.Event();stop_lock=threading.Lock();stop_sent=False
    guard_errors=[];token_file=output/'token.private'

    def stop_product():
        nonlocal stop_sent
        with stop_lock:
            if supervisor is not None and not stop_sent:
                stop_sent=True
                try: supervisor.stdin.write(b'stop\n');supervisor.stdin.flush()
                except (OSError,BrokenPipeError): pass

    def watch_resources():
        while not stop_watch.wait(0.1):
            try:
                for monitor in monitors: monitor.require()
            except Exception as error:
                guard_errors.append(str(error));stop_product();return

    try:
        for rank,host in enumerate(['darkbloom-24','darkbloom-48']):
            monitor=Monitor(host,rank,output);monitors.append(monitor)
            sample=monitor.first.get(timeout=15)
            if sample.get('admissible') is not True: raise RuntimeError('Initial resource sample refused rank '+str(rank))
        lease=AliasLease(LEASE,ROOT.parent/'machines/CREDENTIALS.private.md',output)
        record['aliasReady']=lease.ready()
        for monitor in monitors: monitor.require()
        with (output/'supervisor.stderr').open('xb') as err:
            product_started=time.monotonic()
            supervisor=subprocess.Popen(SSH+['darkbloom-24',shlex.join(['/usr/bin/python3','-B',REMOTE+'/qualification-tools/supervisor.py',remote_run])],
                stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=err,bufsize=0)
        record['supervisorStarted']=line_until(supervisor.stdout,15)
        if record['supervisorStarted'].get('state')!='started': raise RuntimeError('Product supervisor did not start')
        watcher=threading.Thread(target=watch_resources,daemon=True);watcher.start()
        until=time.monotonic()+105;catalog=None
        while time.monotonic()<until:
            for monitor in monitors: monitor.require()
            if supervisor.poll() is not None: raise RuntimeError('Product exited before listener readiness')
            if not token_file.exists() and not fetch_token(token_file):
                time.sleep(0.25);continue
            token=token_file.read_text()
            request=urllib.request.Request('http://192.0.2.250:18081/v1/models',headers={'Authorization':'Bearer '+token})
            try:
                with urllib.request.urlopen(request,timeout=1) as response:
                    raw=response.read(65537)
                    if response.status!=200 or len(raw)>65536: raise RuntimeError('Invalid model catalog')
                    catalog=json.loads(raw)
            except (OSError,ValueError):
                time.sleep(0.25);continue
            if [x['id'] for x in catalog.get('data',[])]!=['Qwen3.5-9B']: raise RuntimeError('Unexpected public model catalog')
            info=discovery()
            if info['pid']!=record['supervisorStarted']['pid'] or info['host']!='192.0.2.250' or info['port']!=18081:
                raise RuntimeError('Listener discovery does not belong to this product process')
            record['discovery']=info
            break
        if catalog is None: raise RuntimeError('Installed product readiness deadline exceeded')
        record['readyAfterSeconds']=time.monotonic()-started
        (output/'catalog.json').write_text(json.dumps(catalog,indent=2)+'\n')
        for monitor in monitors: monitor.require()
        command=['/usr/bin/python3','-B',str(args.client),'--endpoint','http://192.0.2.250:18081/v1/chat/completions',
                 '--model','Qwen3.5-9B','--prompt-file',str(args.prompt_file),'--token-file',str(token_file),
                 '--output',str(output/'client'),'--timeout','90']
        record['clientCommand']=command
        with (output/'client.stdout').open('xb') as out,(output/'client.stderr').open('xb') as err:
            result=subprocess.run(command,stdout=out,stderr=err,timeout=100)
        record['clientExitCode']=result.returncode
    except BaseException as error:
        record['error']=type(error).__name__+': '+str(error)
    finally:
        stop_product()
        if supervisor:
            try:
                tail,_=supervisor.communicate(timeout=40)
                (output/'supervisor.stdout.tail.jsonl').write_bytes(tail)
                record['supervisorExitCode']=supervisor.returncode
                record['supervisorFinal']=[json.loads(line) for line in tail.splitlines() if line.strip()]
            except BaseException as error: record['supervisorCleanupError']=type(error).__name__+': '+str(error)
        try:
            while True:
                values=[]
                for rank,host in enumerate(['darkbloom-24','darkbloom-48']):
                    value=postflight(host,remote_run if rank==0 else None)
                    for name,encoded in value.pop('files').items(): (output/name).write_bytes(base64.b64decode(encoded,validate=True))
                    values.append(value)
                # Keep the alias while native ownership may still be live. The
                # owner/native lifetime is300s after bounded startup. Allow the
                #105s startup observation plus native lifetime before restoring
                # the600s alias lease; elapsed time never clears a journal.
                if all(not value['active'] for value in values) or time.monotonic()-product_started>=420: break
                time.sleep(1)
            record['postflight']=values
            record['nativeProcessesAbsent']=all(not value['active'] for value in values)
            record['journalsEmpty']=all(value['journalBytes']==0 for value in values)
        except BaseException as error: record['postflightError']=type(error).__name__+': '+str(error)
        stop_watch.set()
        if watcher: watcher.join(timeout=2)
        record['guardErrors']=guard_errors
        record['monitors']=[]
        for monitor in monitors:
            try: record['monitors'].append(monitor.stop())
            except BaseException as error: record['monitors'].append({'exitCode':None,'errors':[type(error).__name__+': '+str(error)]})
        if lease:
            try: record['aliasCleanup']=lease.stop()
            except BaseException as error: record['aliasCleanupError']=type(error).__name__+': '+str(error)
        if token_file.exists(): token_file.unlink()
    record['elapsedSeconds']=time.monotonic()-started
    record['pinsUnchanged']=all(hashlib.sha256(Path(p).read_bytes()).hexdigest()==pin for p,pin in pins.items())
    record['completed']=record.get('clientExitCode')==0 and record.get('supervisorExitCode')==0 and record.get('nativeProcessesAbsent') is True and record.get('journalsEmpty') is True and record.get('aliasCleanup',{}).get('restored') is True and not guard_errors and all(m['exitCode']==0 and not m['errors'] for m in record['monitors']) and record['pinsUnchanged'] and 'error' not in record
    (output/'execution.json').write_text(json.dumps(record,indent=2)+'\n')
    print(json.dumps({k:record.get(k) for k in ['completed','error','clientExitCode','supervisorExitCode','nativeProcessesAbsent','journalsEmpty','elapsedSeconds']}),flush=True)
    raise SystemExit(0 if record['completed'] else 1)

if __name__=='__main__':main()
