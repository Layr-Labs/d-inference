"""Root-owned actions: one fresh 48 GiB tiny-state qualification, no model run."""
import argparse
import json
from pathlib import Path
import time
from activation import bind, recheck, sha
from owned_process import invoke_controller

ROOT = Path(__file__).resolve().parent
CASE = 'tiny-state-1'
NAMES = {'deploy-prepare':'deploy-prepare-1', 'install':'install-48-1',
         'case-prepare':'prepare-state-1', 'metadata':'describe-full-1',
         'run':'run-state-1', 'compare':'compare-state-1'}


def verify_source():
    manifest = ROOT/'source-inputs.json'
    for row in json.loads(manifest.read_bytes())['members']:
        path = ROOT/row['path']
        assert path.is_file() and not path.is_symlink()
        assert path.stat().st_size == row['bytes'] and sha(path) == row['sha256']
    required = json.loads((ROOT/'required-native-sources.json').read_bytes())
    assert sha(Path(required['metadataSources']['path'])) == required['metadataSources']['sha256']
    return sha(manifest)


def main():
    p = argparse.ArgumentParser(allow_abbrev=False)
    p.add_argument('action', choices=list(NAMES))
    p.add_argument('--binary', type=Path)
    p.add_argument('--build-receipt', type=Path)
    p.add_argument('--sources', type=Path)
    args = p.parse_args()
    source_sha = verify_source()
    actions = ROOT/'root-actions'; actions.mkdir(mode=0o700, exist_ok=True)
    output = actions/NAMES[args.action]; output.mkdir(mode=0o700)
    receipt = dict(schema='gemma4_mtp_state_root_action_v1', action=args.action,
                   sourceManifestSHA256=source_sha)
    started = time.monotonic()
    try:
        if args.action == 'deploy-prepare':
            assert args.binary and args.build_receipt and args.sources
            activation = bind(args.binary, args.build_receipt, args.sources)
            receipt.update(activationSHA256=sha(ROOT/'activation.json'), **{
                k:activation[k] for k in ('buildReceiptSHA256','sourcesSHA256','nativeSHA256')})
            command = ['deploy.py','prepare','--binary',str(args.binary)]; timeout=150
        else:
            activation = recheck()
            receipt['activationSHA256'] = sha(ROOT/'activation.json')
            assert not args.binary and not args.build_receipt and not args.sources
            if args.action == 'install':
                command=['deploy.py','install','--host','darkbloom-48']; timeout=150
            elif args.action == 'case-prepare':
                command=['run_case.py','prepare','--name',CASE,'--prompt','4096','--cut','7','--chunk','64','--policy','serial']; timeout=30
            elif args.action == 'metadata':
                command=['remote_metadata.py','--case',CASE,'--mode','full','--operation','describe']; timeout=50
            elif args.action == 'run':
                from evidence import Inputs, action
                action(Inputs(),'describe-full-1','metadata',source_sha,sha(ROOT/'activation.json'))
                command=['run_case.py','solo','--name',CASE]; timeout=1020
            else:
                command=['compare.py','--output',str(ROOT/'comparison-1.json')]; timeout=180
        argv=['/usr/bin/python3','-B',str(ROOT/command[0]),*command[1:]]
        receipt['argv']=argv
        with (output/'stdout').open('xb') as stdout, (output/'stderr').open('xb') as stderr:
            invoke_controller(argv,stdout,stderr,receipt,timeout=timeout)
        assert receipt['exitCode']==0 and receipt['reaped'] is True and receipt['groupAbsent'] is True
        assert verify_source()==source_sha and recheck()==activation
        receipt['status']='passed'
    except BaseException as error:
        receipt['status']='failed';receipt['error']=type(error).__name__+': '+str(error)
        raise
    finally:
        receipt['elapsedSeconds']=time.monotonic()-started
        for name in ('stdout','stderr'):
            path=output/name
            if path.exists():receipt[name+'SHA256']=sha(path);receipt[name+'Bytes']=path.stat().st_size
        with (output/'receipt.json').open('x') as stream:
            json.dump(receipt,stream,indent=2);stream.write('\n')
        print(json.dumps(receipt),flush=True)


if __name__=='__main__':main()
