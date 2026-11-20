"""Root-only fresh deployment of exact declared files, then existing preflight."""
from pathlib import Path
import hashlib
import json
import os
import shutil
import subprocess
import time

BASE=Path(__file__).resolve().parent
SSH=['/usr/bin/ssh','-T','-o','BatchMode=yes','-o','ConnectTimeout=8','darkbloom-48','/usr/bin/python3 -B -']


def main():
    metadata=json.loads((BASE/'deployment.json').read_bytes())
    target=Path(metadata['remoteRoot'])
    assert str(target)=='/Users/developer/DarkbloomDev/qwen9b-resident-solo-generation-20260915'
    output=BASE/'deployment-1';output.mkdir(mode=0o700)
    stage=output/'stage';stage.mkdir(mode=0o700)
    # Whitelist exactly38 supervisor members+manifest, the4-file native bundle
    # and2 inputs. Root's later source-review file is deliberately not copied.
    assert len(metadata['files'])==45
    for row in metadata['files']:
        relative=Path(row['path']);source=Path(row['source'])
        assert not relative.is_absolute() and '..' not in relative.parts
        assert source.stat().st_size==row['bytes'] and hashlib.sha256(source.read_bytes()).hexdigest()==row['sha256']
        path=stage/relative;path.parent.mkdir(parents=True,exist_ok=True,mode=0o700)
        shutil.copyfile(source,path);path.chmod(int(row['mode'],8))
    for root,dirs,_ in os.walk(stage):
        Path(root).chmod(0o700)
        for name in dirs:(Path(root)/name).chmod(0o700)
    records=[]
    def invoke(label,argv,data=None,timeout=60):
        began=time.monotonic()
        try:
            result=subprocess.run(argv,input=data,capture_output=True,timeout=timeout)
        except subprocess.TimeoutExpired as error:
            (output/(label+'.stdout')).write_bytes(error.stdout or b'')
            (output/(label+'.stderr')).write_bytes(error.stderr or b'')
            records.append(dict(operation=label,timeout=True,remoteOutcomeUnknown=True));raise
        (output/(label+'.stdout')).write_bytes(result.stdout)
        (output/(label+'.stderr')).write_bytes(result.stderr)
        records.append(dict(operation=label,exitCode=result.returncode,elapsedSeconds=time.monotonic()-began))
        assert result.returncode==0 and not result.stderr,(label,result.returncode,result.stderr.decode(errors='replace'))
        return result.stdout
    passed=False
    try:
        setup="from pathlib import Path\np=Path("+repr(str(target))+ ")\nassert p.parent.resolve()==p.parent\np.mkdir(mode=0o700)\n(p/'runs').mkdir(mode=0o700)\n"
        invoke('prepare',SSH,setup.encode())
        invoke('copy',['/usr/bin/scp','-q','-r','-o','BatchMode=yes','-o','ConnectTimeout=8',
            str(stage/'native'),str(stage/'supervisor'),str(stage/'inputs'),'darkbloom-48:'+str(target)+'/'],timeout=600)
        preflight="import json\nvalue=json.loads("+repr(json.dumps(metadata,separators=(',',':')))+")\n"+(BASE/'remote_preflight.py').read_text()
        checked=json.loads(invoke('verification',SSH,preflight.encode(),timeout=90))
        assert len(checked['verified'])==45 and checked['journal']['bytes']==0 and checked['evidenceEmpty'] is True
        passed=True
    finally:
        (output/'execution.json').write_text(json.dumps(dict(passed=passed,operations=records,
            files=45,modelExecuted=False,remoteRoot=str(target)),indent=2,sort_keys=True)+'\n')
    print(json.dumps(dict(passed=passed,files=45,remoteRoot=str(target))))


if __name__=='__main__':main()
