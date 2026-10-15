"""Individually scheduled C256 diagnostic pair phases with preserved results."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import sys

ROOT=Path(__file__).resolve().parent
EXPERIMENT=ROOT.parent/'resident-generation-phase-memory-draft-20260917/Experiment'
PINS={'serial':'c05c097c90d2058c1ebedaaf7fdca75e731c504739eb5389be0e9e15518bb9c6',
      'lookahead':'1059bb648483b61493a16a7c2bbdf7c7c59c0d58996c187e03a52f6d1873e7c0'}
sys.path.insert(0,str(ROOT.parent/'cluster-native-shared-hardware-go-qualification-draft-20260917'))
from check_process import run_owned

def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()

def main():
    parser=argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument('case',choices=list(PINS))
    parser.add_argument('phase',choices=['copy0','copy1','resources','preflight0','preflight1','run','collect','validate'])
    args=parser.parse_args();case=EXPERIMENT/args.case
    if sha(case/'manifest.json')!=PINS[args.case]: raise ValueError('Reviewed case manifest changed')
    for name,row in json.loads((case/'manifest.json').read_bytes())['files'].items():
        path=case/name
        if path.is_symlink() or path.stat().st_size!=row['bytes'] or sha(path)!=row['sha256']:
            raise ValueError('Frozen case member changed')
    required={'copy1':['copy0'],'resources':['copy1'],'preflight0':['resources'],'preflight1':['preflight0'],
              'run':['preflight1'],'collect':['run'],'validate':['collect']}.get(args.phase,[])
    for phase in required:
        if json.loads((ROOT/(args.case+'-'+phase+'-1/receipt.json')).read_bytes())['status']!='passed':
            raise ValueError('Previous actual phase required')
    command=['/usr/bin/python3','-B']
    if args.phase.startswith('copy'):
        command+=[str(case/'deploy_copy_only.py'),'--rank',args.phase[-1]];timeout=210
    elif args.phase.startswith('preflight'):
        command+=[str(case/'preflight.py'),'--rank',args.phase[-1]];timeout=65
    elif args.phase=='resources': command+=[str(ROOT/'prepare_case_resources.py'),'--case',args.case];timeout=120
    elif args.phase=='run': command+=[str(case/'run_physical.py')];timeout=650
    else:
        command+=[str(EXPERIMENT/('collect.py' if args.phase=='collect' else 'validate_run.py')),'--case',args.case]
        timeout=90
    output=ROOT/(args.case+'-'+args.phase+'-1');output.mkdir(mode=0o700)
    receipt=dict(status='failed',case=args.case,phase=args.phase,caseManifestSHA256=PINS[args.case])
    try:
        receipt['execution']=run_owned(command,output,'execution',timeout)
        receipt['status']='passed'
    finally:
        with (output/'receipt.json').open('x') as stream:
            json.dump(receipt,stream,indent=2,sort_keys=True);stream.write('\n')
    print(json.dumps(receipt,sort_keys=True))

if __name__=='__main__':
    os.umask(0o077);main()
