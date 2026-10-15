import datetime, hashlib, json, os, pathlib, signal, subprocess, sys, time
base=pathlib.Path(__file__).resolve().parent.parent
out=pathlib.Path(__file__).resolve().parent
commands=json.loads((base/'commands.json').read_text())
def sha(p): return hashlib.sha256(p.read_bytes()).hexdigest()
def run(name, argv, timeout, env=None):
    start=time.monotonic(); timed=False; killed=False
    with (out/(name+'.stdout')).open('xb') as stdout, (out/(name+'.stderr')).open('xb') as stderr:
        process=subprocess.Popen(argv,cwd=base,env=os.environ | (env or {}),stdout=stdout,stderr=stderr,start_new_session=True)
        try: code=process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            timed=True
            try: os.killpg(process.pid,signal.SIGTERM)
            except ProcessLookupError: pass
            try: code=process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                killed=True
                try: os.killpg(process.pid,signal.SIGKILL)
                except ProcessLookupError: pass
                code=process.wait(timeout=5)
    receipt={'name':name,'argv':argv,'environmentOverrides':env or {},'exitCode':code,'timedOut':timed,'forcedKill':killed,'elapsedSeconds':time.monotonic()-start,'pid':process.pid,'stdoutSHA256':sha(out/(name+'.stdout')),'stderrSHA256':sha(out/(name+'.stderr')),'compilerPermission':'root explicitly granted','modelExecuted':False,'remoteOperations':False}
    (out/(name+'.json')).write_text(json.dumps(receipt,indent=2)+'\n')
    print(json.dumps({'name':name,'exitCode':code,'seconds':receipt['elapsedSeconds'],'timedOut':timed}),flush=True)
    return code==0 and not timed
print(json.dumps({"runnerPID":os.getpid(),"output":str(out)}),flush=True)
status=True
for step in commands['steps']:
    if not run(step['name'],step['argv'],step['timeoutSeconds'],step.get('environment')):
        status=False;break
    if step['compiler'] and not run(step['name']+'-source-verification',commands['steps'][0]['argv'],60):
        status=False;break
(out/'summary.json').write_text(json.dumps({'passed':status,'commandsSHA256':sha(base/'commands.json'),'utcFinished':datetime.datetime.now(datetime.timezone.utc).isoformat(),'modelExecuted':False,'remoteOperations':False},indent=2)+'\n')
sys.exit(0 if status else 1)
