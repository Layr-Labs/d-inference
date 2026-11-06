"""One explicit root-granted phase; retain all successful and failed outputs."""
import argparse
import json
import os
from retry_inputs import BASE, NUMERICAL, inputs, sha
from bind_activation import activation, comparison
from check_process import run_owned

def main():
    phases = ['controls','prepare','runtime','worker','capability','native','package']
    parser=argparse.ArgumentParser(allow_abbrev=False);parser.add_argument('phase',choices=phases)
    args=parser.parse_args(); inputs(); bound=activation()
    if args.phase != 'controls':
        path=BASE/('root-'+phases[phases.index(args.phase)-1]+'-5/receipt.json')
        previous=json.loads(path.read_bytes())
        if previous['status']!='passed' or previous['manifestSHA256']!=sha(BASE/'manifest.json') or previous['activationSHA256']!=sha(BASE/'activation-1/activation.json'):
            raise ValueError('Matching previous phase must pass naturally')
    output=BASE/('root-'+args.phase+'-5');output.mkdir(mode=0o700)
    receipt=dict(status='failed',phase=args.phase,manifestSHA256=sha(BASE/'manifest.json'),
        activationSHA256=sha(BASE/'activation-1/activation.json'),steps=[])
    try:
        if args.phase=='controls':
            receipt['steps'].append(run_owned(['/usr/bin/python3','-B',str(NUMERICAL/'check_source.py')],output,'source',15))
            receipt['qualifiedComparison']=comparison()
            receipt['newComparatorExecution']=False
        elif args.phase=='prepare':
            receipt['steps'].append(run_owned(['/usr/bin/python3','-B',str(BASE/'prepare.py')],output,'preparation',120))
            result=BASE/'preparation-5/receipt.json'
            if json.loads(result.read_bytes())['status']!='passed': raise ValueError('Source preparation failed')
            receipt['resultSHA256']=sha(result)
        elif args.phase=='package':
            receipt['steps'].append(run_owned(['/usr/bin/python3','-B',str(BASE/'package_native.py'),
                'runtime-5','worker-5','capability-5','native-5','runtime-bundle-5'],output,'execution',180))
            receipt['resultSHA256']=sha(BASE/'runtime-bundle-5/bundle.json')
        else:
            receipt['steps'].append(run_owned(['/usr/bin/python3','-B',str(BASE/'run_checks.py'),
                args.phase,args.phase+'-5'],output,'execution',1100))
            result=BASE/(args.phase+'-5/receipt.json')
            if json.loads(result.read_bytes())['status']!='passed': raise ValueError('Actual phase failed')
            receipt['resultSHA256']=sha(result)
        inputs(); activation(); receipt['status']='passed'
    finally:
        with (output/'receipt.json').open('x') as stream:json.dump(receipt,stream,sort_keys=True,indent=2);stream.write('\n')
    print(json.dumps(receipt,sort_keys=True))

if __name__=='__main__':
    os.umask(0o077);main()
