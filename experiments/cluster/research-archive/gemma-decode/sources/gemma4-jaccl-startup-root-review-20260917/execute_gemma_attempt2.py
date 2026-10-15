"""One explicit Gemma physical action, preserving its owned parent and receipts."""
import argparse
import hashlib
import json
from pathlib import Path
import sys

ROOT = Path('/Users/developer/DarkbloomDev/cluster-research/gemma4-jaccl-startup-progress-draft-20260917')
sys.path.insert(0, str(ROOT))
INPUTS = ROOT / 'preparation-1'
SOURCE = ROOT / 'source'
ACTIONS = ROOT / 'physical-actions-2'
from check_process import run_owned
sys.path[:0] = [str(SOURCE), str(SOURCE / 'package')]
from reference_binding import FULL_DIRECTORY, FULL_RUN, FULL_RUN_SHA


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def check_source(preparation_sha256):
    assert sha(INPUTS / 'receipt.json') == preparation_sha256
    prepared = json.loads((INPUTS / 'receipt.json').read_bytes())
    assert sha(ROOT / 'manifest.json') == prepared['draftManifestSHA256']
    for row in json.loads((ROOT / 'manifest.json').read_bytes())['members']:
        assert sha(ROOT / row['path']) == row['sha256']
    assert sha(SOURCE / 'manifest.json') == prepared['sourceManifestSHA256']
    for row in json.loads((SOURCE / 'manifest.json').read_text())['files']:
        assert sha(SOURCE / row['path']) == row['sha256']


def main():
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument('action', choices=['stages', 'collect-stage0', 'collect-stage1', 'compare'])
    parser.add_argument('--preparation-sha256', required=True)
    args = parser.parse_args()
    prior = ROOT / 'physical-actions-1/stages/action/receipt.json'
    assert sha(prior) == 'b6b789be01546f779303b08bacbf0c673660a500d71a0ee6c2aca8b9cd69cb6b'
    previous = json.loads(prior.read_text())
    assert previous['aliasRelease']['restored'] and previous['retirement']['journalsEmpty'] and previous['retirement']['nativeProcessesAbsent']
    assert previous['retirement']['observationErrors'] == []
    for path, expected in [('/Users/developer/DarkbloomDev/cluster-research/gemma4-jaccl-startup-root-review-20260917/resource-preparation-1/rank0.receipt.json', 'b4767465552533d99c9495a6ce616efd53749736aaa6a0577cac7a9e9a557148'), ('/Users/developer/DarkbloomDev/cluster-research/gemma4-jaccl-startup-root-review-20260917/resource-preparation-1/rank1.receipt.json', '7a879319ff150ae80c9b538e422ef636c5ffa57fb8a5fe952a762859ff5d7765')]:
        assert sha(Path(path)) == expected
        assert json.loads(Path(path).read_text())['passed'] is True
    assert sha(INPUTS / 'receipt.json') == args.preparation_sha256
    check_source(args.preparation_sha256)
    prepared = json.loads((INPUTS / 'receipt.json').read_text())
    assert prepared['status'] == 'passed'
    source_sha = prepared['sourceManifestSHA256']
    bound = ROOT / 'bound'
    binding_sha = sha(bound / 'binding-receipt.json')
    assert binding_sha == prepared['bindingReceiptSHA256']
    ACTIONS.mkdir(mode=0o700, exist_ok=True)
    output = ACTIONS / args.action
    output.mkdir(mode=0o700)
    command = ['/usr/bin/python3', '-B', str(SOURCE / 'run_physical.py')]
    bound_args = ['--bound', str(bound), '--binding-sha256', binding_sha,
                  '--output', str(output / 'action')]

    def pin(label, flag):
        if label == 'full':
            return [flag, str(FULL_RUN), '--full-run-sha256', FULL_RUN_SHA]
        previous = (ROOT / 'physical-actions-1' if label == 'copy' else ACTIONS) / label
        outer = json.loads((previous / 'receipt.json').read_text())
        assert outer['status'] == 'passed' and outer['bindingSHA256'] == binding_sha
        path = previous / 'action/receipt.json'
        assert sha(path) == outer['actionReceiptSHA256']
        return [flag, str(path), flag + '-sha256' if flag == '--copy-proof' else flag.replace('-receipt', '-sha256'), sha(path)]

    if args.action == 'copy':
        command += ['copy'] + bound_args
        timeout = 800
    elif args.action in ('full', 'stages'):
        command += ['run', '--mode', args.action, '--attempt', '2'] + bound_args
        command += pin('copy', '--copy-proof')
        if args.action == 'stages':
            command += ['--full-dir', str(FULL_DIRECTORY)]
            command += pin('full', '--full-run-receipt')
        timeout = 540
    elif args.action.startswith('collect-'):
        command += ['collect', '--mode', args.action[len('collect-'):], '--attempt', '2'] + bound_args
        timeout = 90
    else:
        command += ['compare'] + bound_args
        for mode in ('full', 'stage0', 'stage1'):
            command += ['--' + mode + '-dir', str(FULL_DIRECTORY if mode == 'full' else ACTIONS / ('collect-' + mode) / 'action/returned')]
        command += pin('full', '--full-run-receipt') + pin('stages', '--stages-run-receipt')
        timeout = 150
    receipt = dict(status='failed', action=args.action, bindingSHA256=binding_sha,
                   sourceManifestSHA256=source_sha, argv=command)
    try:
        receipt['child'] = run_owned(command, output, 'execution', timeout)
        check_source(args.preparation_sha256)
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
