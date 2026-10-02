"""Root-granted only: owned, bounded model-free parser and actual-child checks."""
import json
from pathlib import Path
import sys
from check_process import run_owned
from check_source import check, sha

BASE = Path(__file__).resolve().parent


def main():
    attempt = int(sys.argv[1])
    if not 1 <= attempt <= 9: raise ValueError('Bounded fresh attempt required')
    check(); output = BASE / ('cpu-%d' % attempt); output.mkdir(mode=0o700)
    receipt = dict(status='failed', nativeOrModelExecuted=False, remoteExecuted=False)
    try:
        receipt['child'] = run_owned(['/usr/bin/python3', '-B', str(BASE / 'Tests/test_startup_stderr.py')],
                                     output, 'checks', 30)
        check(); receipt['status'] = 'passed'
    finally:
        with (output / 'receipt.json').open('x') as stream:
            json.dump(receipt, stream, sort_keys=True, indent=2); stream.write('\n')
    print(json.dumps(dict(status='passed', receiptSHA256=sha(output / 'receipt.json'))))


if __name__ == '__main__': main()
