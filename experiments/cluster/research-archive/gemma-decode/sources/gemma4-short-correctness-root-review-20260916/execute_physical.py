"""One explicit Gemma physical action, preserving its owned parent and receipts."""
import argparse
import hashlib
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parent
SOURCE = ROOT.parent / 'gemma4-short-physical-reviewed-source-20260917'
SOURCE_SHA = 'a5f09155ff91016c197a6bc4c1dc62757b82f3589dd53879dab2c46eba7f952d'
INPUTS = ROOT / 'actual-inputs-1'
ACTIONS = ROOT / 'physical-actions-1'
sys.path.insert(0, str(ROOT.parent / 'cluster-native-member-invocation-draft-20260916/Tests'))
from check_process import run_owned


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def check_source():
    assert sha(SOURCE / 'manifest.json') == SOURCE_SHA
    for row in json.loads((SOURCE / 'manifest.json').read_text())['files']:
        assert sha(SOURCE / row['path']) == row['sha256']


def main():
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument('action', choices=['copy', 'full', 'collect-full', 'stages',
                                         'collect-stage0', 'collect-stage1', 'compare'])
    args = parser.parse_args()
    check_source()
    prepared = json.loads((INPUTS / 'receipt.json').read_text())
    assert prepared['status'] == 'passed' and prepared['sourceManifestSHA256'] == SOURCE_SHA
    bound = INPUTS / 'bound'
    binding_sha = sha(bound / 'binding-receipt.json')
    assert binding_sha == prepared['bindingReceiptSHA256']
    ACTIONS.mkdir(mode=0o700, exist_ok=True)
    output = ACTIONS / args.action
    output.mkdir(mode=0o700)
    command = ['/usr/bin/python3', '-B', str(SOURCE / 'run_physical.py')]
    bound_args = ['--bound', str(bound), '--binding-sha256', binding_sha,
                  '--output', str(output / 'action')]

    def pin(label, flag):
        previous = ACTIONS / label
        outer = json.loads((previous / 'receipt.json').read_text())
        assert outer['status'] == 'passed' and outer['bindingSHA256'] == binding_sha
        path = previous / 'action/receipt.json'
        assert sha(path) == outer['actionReceiptSHA256']
        return [flag, str(path), flag + '-sha256' if flag == '--copy-proof' else flag.replace('-receipt', '-sha256'), sha(path)]

    if args.action == 'copy':
        command += ['copy'] + bound_args
        timeout = 800
    elif args.action in ('full', 'stages'):
        command += ['run', '--mode', args.action, '--attempt', '1'] + bound_args
        command += pin('copy', '--copy-proof')
        if args.action == 'stages':
            command += ['--full-dir', str(ACTIONS / 'collect-full/action/returned')]
            command += pin('full', '--full-run-receipt')
        timeout = 540
    elif args.action.startswith('collect-'):
        command += ['collect', '--mode', args.action[len('collect-'):], '--attempt', '1'] + bound_args
        timeout = 90
    else:
        command += ['compare'] + bound_args
        for mode in ('full', 'stage0', 'stage1'):
            command += ['--' + mode + '-dir', str(ACTIONS / ('collect-' + mode) / 'action/returned')]
        command += pin('full', '--full-run-receipt') + pin('stages', '--stages-run-receipt')
        timeout = 150
    receipt = dict(status='failed', action=args.action, bindingSHA256=binding_sha,
                   sourceManifestSHA256=SOURCE_SHA, argv=command)
    try:
        receipt['child'] = run_owned(command, output, 'execution', timeout)
        check_source()
        assert sha(bound / 'binding-receipt.json') == binding_sha
        action_receipt = output / 'action/receipt.json'
        assert json.loads(action_receipt.read_text())['status'] == 'passed'
        receipt.update(status='passed', actionReceiptSHA256=sha(action_receipt))
    finally:
        with (output / 'receipt.json').open('x') as stream:
            json.dump(receipt, stream, indent=2, sort_keys=True)
            stream.write('\n')
    print(json.dumps(dict(status='passed', action=args.action,
                         receiptSHA256=sha(output / 'receipt.json'))))


if __name__ == '__main__':
    main()
