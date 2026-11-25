"""Root-granted bounded CPU controls; preserve failures and owned-child terminal proof."""
import argparse
import hashlib
import json
from pathlib import Path
import sys
import time
from owned_process import invoke_controller
BASE=Path(__file__).resolve().parent.parent


def verify():
    for directory in [BASE/'Compare',BASE/'Physical',BASE/'Tests']:
        for row in json.loads((directory/'manifest.json').read_bytes())['files']:
            path=directory/row['path'];raw=path.read_bytes()
            if path.is_symlink() or len(raw)!=row['bytes'] or hashlib.sha256(raw).hexdigest()!=row['sha256']:
                raise ValueError('Qualification source changed')


def main():
    parser=argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument('--output',required=True,type=Path);args=parser.parse_args()
    if not args.output.is_absolute() or args.output!=args.output.resolve() or args.output.exists():
        raise ValueError('Fresh canonical output required')
    verify();args.output.mkdir(mode=0o700);receipt=dict(status='started',nativeExecuted=False,compilerExecuted=False,remoteExecuted=False)
    start=time.monotonic()
    try:
        with (args.output/'stdout').open('xb') as out,(args.output/'stderr').open('xb') as err:
            invoke_controller([sys.executable,'-B',str(BASE/'Tests/entry.py')],out,err,receipt,timeout=30)
        if receipt.get('exitCode')!=0 or not receipt.get('reaped') or not receipt.get('groupAbsent'):
            raise ValueError('CPU child did not pass/retire')
        actual=json.loads((args.output/'stdout').read_bytes())
        if actual!=dict(status='passed',tests=16,failures=0,errors=0,nativeExecuted=False,remoteExecuted=False):
            raise ValueError('Expected all16 CPU controls')
        verify();receipt.update(status='passed',result=actual,sourcePinsUnchanged=True)
    except BaseException as error:
        receipt.update(status='failed',failure=type(error).__name__+': '+str(error));raise
    finally:
        receipt['elapsedSeconds']=time.monotonic()-start
        for name in ['stdout','stderr']:
            path=args.output/name
            if path.exists():receipt[name+'SHA256']=hashlib.sha256(path.read_bytes()).hexdigest()
        (args.output/'receipt.json').write_text(json.dumps(receipt,indent=2,sort_keys=True)+'\n')


if __name__=='__main__':main()
