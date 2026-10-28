"""Sequential qualified phases, each bounded with the retained owned helper."""
import argparse
import json
import os
from retry_inputs import BASE, inputs, sha
from check_process import run_owned

def main():
    phases = ['prepare','runtime','worker','capability','native','package']
    parser = argparse.ArgumentParser(allow_abbrev=False); parser.add_argument('phase', choices=phases)
    args = parser.parse_args(); inputs()
    if args.phase != 'prepare':
        name = phases[phases.index(args.phase)-1]
        record = json.loads((BASE / ('root-'+name+'-7/receipt.json')).read_bytes())
        if record['status'] != 'passed' or record['manifestSHA256'] != sha(BASE/'manifest.json'):
            raise ValueError('Matching previous phase must pass')
    output = BASE / ('root-'+args.phase+'-7'); output.mkdir(mode=0o700)
    receipt = dict(status='failed', phase=args.phase, manifestSHA256=sha(BASE/'manifest.json'), steps=[])
    try:
        if args.phase == 'prepare':
            command = ['/usr/bin/python3','-B',str(BASE/'prepare.py')]; timeout=120
            result = BASE/'preparation-7/receipt.json'
        elif args.phase == 'package':
            command = ['/usr/bin/python3','-B',str(BASE/'package_native.py'),'runtime-7','worker-7','capability-7','native-7','runtime-bundle-7']; timeout=180
            result = BASE/'runtime-bundle-7/bundle.json'
        else:
            command = ['/usr/bin/python3','-B',str(BASE/'run_checks.py'),args.phase,args.phase+'-7']; timeout=1100
            result = BASE/(args.phase+'-7/receipt.json')
        receipt['steps'].append(run_owned(command,output,'execution',timeout))
        if args.phase != 'package' and json.loads(result.read_bytes())['status'] != 'passed':
            raise ValueError('Actual phase failed')
        inputs(); receipt.update(status='passed', resultSHA256=sha(result))
    finally:
        with (output/'receipt.json').open('x') as stream: json.dump(receipt,stream,indent=2,sort_keys=True);stream.write('\n')
    print(json.dumps(receipt,sort_keys=True))

if __name__ == '__main__':
    os.umask(0o077); main()
