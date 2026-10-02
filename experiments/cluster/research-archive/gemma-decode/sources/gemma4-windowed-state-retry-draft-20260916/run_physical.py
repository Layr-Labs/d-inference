"""Root-owned copy, one bounded physical check, or evidence collection."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import shlex
import signal
import subprocess
import sys
import time

ROOT=Path(__file__).resolve().parent
sys.dont_write_bytecode=True
ORIGINAL=Path('/Users/developer/DarkbloomDev/cluster-research/gemma4-windowed-state-supervisor-20260916')
sys.path.insert(0,str(ORIGINAL/'package'))
from binding_common import canonical,require
from binding_inputs import snapshot
from target_inputs import write_json,write_new


def verify():
    manifest=json.loads((ROOT/'manifest.json').read_text())
    for row in manifest['files']:
        item=snapshot(ROOT/row['path'],max(row['bytes'],1),keep=False,empty=True)
        require(item['size_bytes']==row['bytes'] and item['sha256']==row['sha256'],'Local frozen member differs')
    lineage=json.loads((ROOT/'lineage.json').read_text())
    prior=snapshot(ORIGINAL/'manifest.json',1024**2)['raw']
    require(hashlib.sha256(prior).hexdigest()==lineage['baseManifestSHA256'],'Original source manifest differs')
    for row in json.loads(prior)['files']:
        item=snapshot(ORIGINAL/row['path'],max(row['bytes'],1),keep=False,empty=True)
        require(item['size_bytes']==row['bytes'] and item['sha256']==row['sha256'],'Original frozen member differs')
    commands=json.loads((ROOT/'ROOT-COMMANDS.json').read_text())
    known=commands['knownHosts']
    require(snapshot(known['path'],1024**2)['sha256']==known['sha256'],'Pinned known_hosts differs')
    return commands


def execute(argv,directory,name,seconds,stdin=None,output_cap=16*1024**2):
    started=time.monotonic(); child=None; failure=None
    outpath=directory/(name+'.stdout'); errpath=directory/(name+'.stderr')
    with outpath.open('xb') as output,errpath.open('xb') as error:
        try:
            child=subprocess.Popen(argv,stdin=stdin if stdin is not None else subprocess.DEVNULL,
                stdout=output,stderr=error,start_new_session=True)
            write_json(directory/(name+'.launched.json'),dict(pid=child.pid,argv=argv,timeoutSeconds=seconds))
            while child.poll() is None:
                require(time.monotonic()-started<seconds,'Owned subprocess deadline expired')
                require(outpath.stat().st_size+errpath.stat().st_size<=output_cap,'Owned output bound exceeded')
                time.sleep(0.05)
            require(outpath.stat().st_size+errpath.stat().st_size<=output_cap,'Final output bound exceeded')
        except BaseException as e:
            failure=type(e).__name__+': '+str(e)[:2048]
            if child is not None and child.returncode is None:
                try: os.killpg(child.pid,signal.SIGKILL)
                except ProcessLookupError: pass
                child.wait(timeout=5)
            raise
        finally:
            write_json(directory/(name+'.execution.json'),dict(exitCode=child.returncode if child else None,
                elapsedSeconds=time.monotonic()-started,failure=failure,
                stdoutSHA256=hashlib.sha256(outpath.read_bytes()).hexdigest(),
                stderrSHA256=hashlib.sha256(errpath.read_bytes()).hexdigest()))
    return child.returncode


def main():
    parser=argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument('action',choices=['copy','run','collect'])
    parser.add_argument('--fixture',choices=['window','session','target'])
    parser.add_argument('--attempt',type=int,choices=range(1,10),default=1)
    args=parser.parse_args(); os.umask(0o077); commands=verify()
    require((args.action=='copy') == (args.fixture is None), 'Copy has no fixture; run/collect require one')
    require(args.action!='copy' or args.attempt==1,'Copy is a single fresh operation')
    suffix='' if args.fixture is None else '-'+args.fixture
    directory=ROOT/('physical-'+args.action+suffix+'-'+str(args.attempt));directory.mkdir(mode=0o700)
    if args.action=='copy':
        code=execute(commands['copyProducer'],directory,'stream',180,output_cap=1024**2)
        require(code==0,'Local stream preparation failed')
        with (directory/'stream.stdout').open('rb') as stream:
            code=execute(commands['copyRemote'],directory,'ssh',commands['copyTimeoutSeconds'],stdin=stream)
        if code==0:
            receipt=json.loads((directory/'ssh.stdout').read_text())
            require(receipt['manifestSHA256']==commands['deploymentSHA256'],'Installed deployment differs')
            require(receipt['modelOrOwnerLaunched'] is False,'Unexpected copy behavior')
        return code
    if args.action=='run':
        require((ROOT/'physical-copy-1/ssh.execution.json').exists(),'Copy proof missing')
        require(json.loads((ROOT/'physical-copy-1/ssh.execution.json').read_text())['exitCode']==0,'Copy did not succeed')
        command=shlex.join(commands['runArguments'][args.fixture]+['--attempt',str(args.attempt)])
        return execute(commands['sshPrefix']+[command],directory,'ssh',commands['runTimeoutSeconds'])
    command=shlex.join(['/usr/bin/python3','-B','-c',(ROOT/'collect_remote.py').read_text(),args.fixture,str(args.attempt)])
    code=execute(commands['sshPrefix']+[command],directory,'ssh',45)
    require(code==0,'Read-only collection failed')
    receipt=json.loads((directory/'ssh.stdout').read_text()); returned=directory/'returned';returned.mkdir(mode=0o700)
    total=0
    for name,row in receipt['files'].items():
        relative=Path(name)
        require(not relative.is_absolute() and '..' not in relative.parts and str(relative)==name,'Unsafe evidence member')
        raw=base64.b64decode(row['base64'],validate=True);total+=len(raw)
        require(len(raw)==row['bytes'] and hashlib.sha256(raw).hexdigest()==row['sha256'] and total<=8*1024**2,'Evidence hash or size differs')
        destination=returned/relative;destination.parent.mkdir(mode=0o700,parents=True,exist_ok=True);write_new(destination,raw)
    write_json(directory/'collection.json',dict(files={k:{a:b for a,b in v.items() if a!='base64'} for k,v in receipt['files'].items()},
        processes=receipt['processes'],journal=receipt['journal']))
    print(json.dumps(dict(collected=len(receipt['files']),journal=receipt['journal'],processes=receipt['processes'])),flush=True)
    return 0


if __name__=='__main__': raise SystemExit(main())
