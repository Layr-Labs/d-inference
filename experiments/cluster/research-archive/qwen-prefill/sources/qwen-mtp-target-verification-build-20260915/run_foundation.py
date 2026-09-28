"""Explicitly granted Foundation-only slot; bounded owned compiler/test groups."""
from pathlib import Path
import hashlib,json,os,signal,subprocess,sys,time
BASE=Path(__file__).resolve().parent

def pin(path):return hashlib.sha256(path.read_bytes()).hexdigest()

def main():
    output=BASE/sys.argv[1];output.mkdir(mode=0o700)
    args=json.loads((BASE/'foundation-command.json').read_bytes())
    args[-1]=str(output/'target-verification-check')
    inputs={str(Path(x).relative_to(BASE)):pin(Path(x)) for x in args if x.endswith('.swift')}
    (output/'input-pins.json').write_text(json.dumps(inputs,indent=2,sort_keys=True)+'\n')
    (output/'Tests').mkdir()
    for source in (BASE/'foundation/Tests').glob('*.swift'):(output/'Tests'/source.name).write_bytes(source.read_bytes())
    receipt=dict(scope='Foundation-only contracts; no MLX/GPU/model/remote',steps=[],sourcePins=inputs)
    def run(name,command,bound):
        start=time.monotonic()
        with (output/(name+'.stdout')).open('xb') as out,(output/(name+'.stderr')).open('xb') as err:
            child=subprocess.Popen(command,stdout=out,stderr=err,start_new_session=True)
            print(name+' pid '+str(child.pid),flush=True)
            failure=None
            try:code=child.wait(timeout=bound)
            except BaseException as error:
                failure=type(error).__name__+': '+str(error)
                try:os.killpg(child.pid,signal.SIGKILL)
                except ProcessLookupError:pass
                child.wait();code=child.returncode
        receipt['steps'].append(dict(name=name,argv=command,pid=child.pid,exitCode=code,elapsedSeconds=time.monotonic()-start,failure=failure,stdoutSHA256=pin(output/(name+'.stdout')),stderrSHA256=pin(output/(name+'.stderr'))))
        receipt['sourceInputsUnchanged']=all(pin(BASE/n)==v for n,v in inputs.items())
        (output/'receipt.json').write_text(json.dumps(receipt,indent=2,sort_keys=True)+'\n')
        print(name+' terminal '+str(code),flush=True)
        if code!=0 or failure:raise SystemExit(code if code else 1)
    run('compile',args,60)
    run('check',[args[-1]],10)
    assert receipt['sourceInputsUnchanged']
    receipt['status']='passed';(output/'receipt.json').write_text(json.dumps(receipt,indent=2,sort_keys=True)+'\n')

if __name__=='__main__':main()
