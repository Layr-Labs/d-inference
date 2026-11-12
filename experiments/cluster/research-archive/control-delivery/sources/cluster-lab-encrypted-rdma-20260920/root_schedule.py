"""Sequential, owned execution of explicitly selected lab payload cases."""
import argparse
import json
from pathlib import Path
import sys
import time

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT.parent / 'cluster-lab-encrypted-rdma-build-20260920'))
from owned_process import invoke_controller


def main():
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument('--round', type=int, required=True)
    parser.add_argument('--payloads', type=int, nargs='+', required=True)
    args = parser.parse_args()
    for payload in args.payloads:
        name = 'p' + str(payload) + '-' + str(args.round)
        output = ROOT / ('root-' + name)
        output.mkdir(mode=0o700)
        receipt = dict(status='started', steps=[])
        start = time.monotonic()
        try:
            for action, timeout in [('prepare', 30), ('pair', 1100)]:
                command = [sys.executable, '-B', str(ROOT / 'run_case.py'), action, '--name', name]
                if action == 'prepare': command += ['--payload', str(payload)]
                step = dict(action=action)
                receipt['steps'].append(step)
                with (output / (action + '.stdout')).open('xb') as stdout, (output / (action + '.stderr')).open('xb') as stderr:
                    invoke_controller(command, stdout, stderr, step, timeout=timeout)
                if step.get('exitCode') != 0 or not step.get('reaped') or not step.get('groupAbsent') or step.get('failure'):
                    raise ValueError('Owned lab action did not pass: ' + name + '/' + action)
            returned = json.loads((ROOT / 'cases' / name / 'pair/receipt.json').read_bytes())
            if returned['status'] != 'completed' or not returned['aliasRelease']['restored'] or not returned['localSecretFileRemoved']:
                raise ValueError('Physical result did not retire successfully')
            receipt['status'] = 'passed'
            result = json.loads((ROOT / 'cases' / name / 'pair/comparison.json').read_bytes())
            print(json.dumps(dict(case=name, status='passed', medianRoundtripNanoseconds=result['rank0RoundtripMedianNanoseconds'])), flush=True)
        except BaseException as error:
            receipt.update(status='failed', failure=type(error).__name__ + ': ' + str(error))
            raise
        finally:
            receipt['elapsedSeconds'] = time.monotonic() - start
            (output / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')


if __name__ == '__main__':
    main()
