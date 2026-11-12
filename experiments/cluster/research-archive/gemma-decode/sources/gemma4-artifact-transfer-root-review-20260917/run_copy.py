"""One explicit host copy through the reviewed owned parent."""
import argparse
import hashlib
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parent
RESEARCH = ROOT.parent
SOURCE = RESEARCH / 'gemma4-artifact-transfer-owned-group-ready-20260917'
SOURCE_SHA = '84051f47597567bd173826984dfcab2ebd231cc31743631010ba4894f76e86dc'
LOCAL = RESEARCH / 'gemma4-artifact-local-verification-20260917'
sys.path.insert(0, str(RESEARCH / 'cluster-native-member-invocation-draft-20260916/Tests'))
from check_process import run_owned


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def check_source():
    assert sha(SOURCE / 'manifest.json') == SOURCE_SHA
    for row in json.loads((SOURCE / 'manifest.json').read_text())['files']:
        assert sha(SOURCE / row['path']) == row['sha256']


def main():
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument('host', choices=['darkbloom-24', 'darkbloom-48'])
    args = parser.parse_args()
    check_source()
    verification = json.loads((ROOT / 'local-run-1/receipt.json').read_text())
    assert verification['status'] == 'passed' and verification['sourceManifestSHA256'] == SOURCE_SHA
    local_sha = sha(LOCAL / 'receipt.json')
    assert verification['localReceiptSHA256'] == local_sha
    assert json.loads((LOCAL / 'receipt.json').read_text())['status'] == 'passed'
    output = ROOT / ('copy-' + args.host + '-1')
    output.mkdir(mode=0o700)
    destination = RESEARCH / ('gemma4-artifact-copy-' + args.host + '-20260917')
    record = dict(status='failed', host=args.host, localVerificationSHA256=local_sha,
                  sourceManifestSHA256=SOURCE_SHA)
    try:
        record['child'] = run_owned(['/usr/bin/python3', '-B', str(SOURCE / 'copy_host.py'),
            '--host', args.host, '--verified', str(LOCAL), '--receipt-sha256', local_sha,
            '--output', str(destination)], output, 'copy', 1300)
        value = json.loads((destination / 'receipt.json').read_text())
        assert value['status'] == 'passed' and value['host'] == args.host
        check_source()
        record.update(status='passed', copyReceiptSHA256=sha(destination / 'receipt.json'))
    finally:
        with (output / 'receipt.json').open('x') as stream:
            json.dump(record, stream, indent=2, sort_keys=True)
            stream.write('\n')
    print(json.dumps(dict(status='passed', host=args.host, copyReceiptSHA256=record['copyReceiptSHA256'])))


if __name__ == '__main__':
    main()
