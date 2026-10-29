"""One installed HTTP disconnect, autonomous-cleanup observation, then fallback."""
from pathlib import Path
import argparse, base64, hashlib, json, os, shlex, subprocess, threading, time
import urllib.request
from guards import AliasLease, Monitor, SSH, REMOTE
from lease_source import LEASE
from physical_io import line_until, fetch_token, postflight, discovery
from tokenizer_check import verify as verify_tokenizer
from cancellation_observation import observe_after_close

BASE=Path(__file__).resolve().parent
ROOT=BASE.parents[1]  # cluster-research; private derivative is nested one level

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--attempt',required=True,type=int)
    parser.add_argument('--prompt-file',required=True,type=Path)
    parser.add_argument('--client',required=True,type=Path)
    parser.add_argument('--mode',required=True,choices=['before-content','after-two-content'])
    parser.add_argument('--cancel-after-seconds',type=float,default=0.5)
    parser.add_argument('--self-retirement-seconds',type=float,default=30)
    parser.add_argument('--declared-prompt-tokens',type=int)
    parser.add_argument('--rendered-prompt',type=Path)
    parser.add_argument('--expected-token-ids',type=Path)
    args=parser.parse_args()
    assert 1<=args.attempt<=99
    assert args.declared_prompt_tokens is None or 1<=args.declared_prompt_tokens<=8192
    assert (args.rendered_prompt is None)==(args.expected_token_ids is None)
    assert 0<args.cancel_after_seconds<=30
    assert 1<=args.self_retirement_seconds<=60
    output=BASE/('physical-'+str(args.attempt));output.mkdir(mode=0o700)
    remote_run=REMOTE+'/qualification/cancel-'+args.mode+'-attempt'+str(args.attempt)
    record={'schema':'installed_distributed_http_cancel_attempt_v1','startedUnix':time.time(),
            'representativePerformanceQualified':False,'openRouterQualified':False,
            'numericalReferenceCompared':False,'requestCount':1,'mode':args.mode,
            'recoveryRequestQualified':False,'requestCancellationCauseIndependentlyVerified':False}
    record['declaredPromptTokens']=args.declared_prompt_tokens
    codefiles=sorted(BASE.glob('*.py'))+sorted(args.client.parent.glob('*.py'))+[args.prompt_file]
    if args.rendered_prompt is not None:
        codefiles.extend([args.rendered_prompt,args.expected_token_ids])
    pins={str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in codefiles}
    (output/'input-pins.json').write_text(json.dumps(pins,indent=2)+'\n')
    started=time.monotonic();product_started=started;monitors=[];lease=None;supervisor=None;watcher=None
    stop_watch=threading.Event();stop_lock=threading.Lock();stop_sent=False
    guard_errors=[];token_file=output/'token.private'

    def stop_product(reason):
        nonlocal stop_sent
        with stop_lock:
            if supervisor is not None and supervisor.poll() is None and not stop_sent:
                stop_sent=True
                record['parentStopIssued']={'reason':reason,'afterProductStartSeconds':time.monotonic()-product_started}
                try: supervisor.stdin.write(b'stop\n');supervisor.stdin.flush()
                except (OSError,BrokenPipeError): pass

    def watch_resources():
        while not stop_watch.wait(0.1):
            try:
                for monitor in monitors: monitor.require()
            except Exception as error:
                guard_errors.append(str(error));stop_product('resource-guard');return

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
        if args.rendered_prompt is not None:
            record['tokenizerCheck']=verify_tokenizer(args.rendered_prompt,args.expected_token_ids,token,output)
        for monitor in monitors: monitor.require()
        command=['/usr/bin/python3','-B',str(args.client),'--endpoint','http://192.0.2.250:18081/v1/chat/completions',
                 '--model','Qwen3.5-9B','--prompt-file',str(args.prompt_file),'--token-file',str(token_file),
                 '--output',str(output/'client'),'--timeout','90','--mode',args.mode,
                 '--cancel-after-seconds',str(args.cancel_after_seconds)]
        if args.declared_prompt_tokens is not None:
            command.extend(['--declared-prompt-tokens',str(args.declared_prompt_tokens)])
        record['clientCommand']=command
        with (output/'client.stdout').open('xb') as out,(output/'client.stderr').open('xb') as err:
            result=subprocess.run(command,stdout=out,stderr=err,timeout=100)
        record['clientExitCode']=result.returncode
        raw_receipt=(output/'client/receipt.json').read_bytes()
        if len(raw_receipt)>131072: raise RuntimeError('Client receipt exceeded bound')
        client_receipt=json.loads(raw_receipt)
        record['clientReceiptSHA256']=hashlib.sha256(raw_receipt).hexdigest()
        if result.returncode!=0 or client_receipt.get('requested_disconnect_observed') is not True:
            raise RuntimeError('Client did not observe requested disconnect phase')
        record['requestedClientDisconnectObserved']=True
        origin=client_receipt['request_start_monotonic_ns']
        closed=client_receipt['connection_close_returned_ns']
        if type(origin) is not int or type(closed) is not int or min(origin,closed)<0:
            raise RuntimeError('Invalid same-Mac client monotonic timestamps')
        close_origin=(origin+closed)/1e9
        observation_files=output/'self-retirement-files';observation_files.mkdir()
        sample_number=0
        def collect(rank,timeout):
            nonlocal sample_number
            value=postflight(['darkbloom-24','darkbloom-48'][rank],remote_run if rank==0 else None,timeout=timeout)
            files=value.pop('files')
            for name,encoded in files.items():
                if name not in ['provider.stdout','provider.stderr','supervisor.json']:
                    raise RuntimeError('Unexpected postflight file')
                (observation_files/(str(sample_number)+'-'+name)).write_bytes(base64.b64decode(encoded,validate=True))
            sample_number+=1
            return value
        # No stop/EOF is sent during this window. Resource guards remain active
        # and make autonomous cleanup unqualified if they intervene.
        record['selfRetirement']=observe_after_close(close_origin,args.self_retirement_seconds,
            collect,lambda:stop_sent or bool(guard_errors))
    except BaseException as error:
        record['error']=type(error).__name__+': '+str(error)
    finally:
        record['fallbackEnteredAfterProductStartSeconds']=time.monotonic()-product_started
        stop_product('post-observation-cleanup-fallback')
        if supervisor:
            try:
                tail,_=supervisor.communicate(timeout=40)
                (output/'supervisor.stdout.tail.jsonl').write_bytes(tail)
                record['supervisorExitCode']=supervisor.returncode
                record['supervisorFinal']=[json.loads(line) for line in tail.splitlines() if line.strip()]
            except BaseException as error: record['supervisorCleanupError']=type(error).__name__+': '+str(error)
        postflight_errors=[]
        while True:
            try:
                try:
                    values=[]
                    for rank,host in enumerate(['darkbloom-24','darkbloom-48']):
                        value=postflight(host,remote_run if rank==0 else None)
                        for name,encoded in value.pop('files').items(): (output/name).write_bytes(base64.b64decode(encoded,validate=True))
                        values.append(value)
                    record['postflight']=values
                    record['nativeProcessesAbsent']=all(not value['active'] for value in values)
                    record['journalsEmpty']=all(value['journalBytes']==0 for value in values)
                except Exception as error:
                    postflight_errors.append(type(error).__name__+': '+str(error))
                    record['nativeProcessesAbsent']=False
                    record['journalsEmpty']=False
                # Keep the alias while native ownership may still be live. The
                # owner/native lifetime is300s after bounded startup. Allow the
                #105s startup observation plus native lifetime before restoring
                # the600s alias lease; elapsed time never clears a journal.
                if record.get('nativeProcessesAbsent') is True or time.monotonic()-product_started>=420: break
                time.sleep(1)
            except BaseException as error:
                # Defer an operator interruption until cleanup is proven or
                # the bounded native ownership lifetime has expired.
                detail=type(error).__name__+': '+str(error)
                record['postflightError']=detail
                record.setdefault('error', 'Interrupted during postflight: '+detail)
                postflight_errors.append(detail)
                record['nativeProcessesAbsent']=False
                record['journalsEmpty']=False
                if time.monotonic()-product_started>=420: break
        record['postflightObservationErrors']=postflight_errors
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
    finals=record.get('supervisorFinal',[])
    record['supervisorNaturalExitObserved']=len(finals)==1 and finals[0].get('state')=='exited' and finals[0].get('stopReason')=='natural-exit' and finals[0].get('forcedKill') is False and type(finals[0].get('exitCode')) is int and finals[0]['exitCode'] in (0,1) and record.get('supervisorExitCode')==finals[0]['exitCode']
    record['completed']=record.get('requestedClientDisconnectObserved') is True and record.get('selfRetirement',{}).get('self_retirement_observed') is True and record.get('selfRetirement',{}).get('harness_interference_observed') is False and record['supervisorNaturalExitObserved'] and record.get('nativeProcessesAbsent') is True and record.get('journalsEmpty') is True and record.get('aliasCleanup',{}).get('restored') is True and not guard_errors and all(m['exitCode']==0 and not m['errors'] for m in record['monitors']) and record['pinsUnchanged'] and 'error' not in record
    (output/'execution.json').write_text(json.dumps(record,indent=2)+'\n')
    print(json.dumps({k:record.get(k) for k in ['completed','error','clientExitCode','supervisorExitCode','supervisorNaturalExitObserved','nativeProcessesAbsent','journalsEmpty','elapsedSeconds']}),flush=True)
    raise SystemExit(0 if record['completed'] else 1)

if __name__=='__main__':main()
