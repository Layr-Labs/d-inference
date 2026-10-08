"""Guarded local additions; --apply requires a separate root promotion grant."""
import argparse
import hashlib
import json
import os
from pathlib import Path

BASE = Path(__file__).resolve().parent


def check_file(row, key='path'):
    path = Path(row[key])
    raw = path.read_bytes()
    if len(raw) != row['sizeBytes'] or hashlib.sha256(raw).hexdigest() != row['sha256']:
        raise ValueError('Pinned input changed: ' + str(path))
    return raw


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--apply', action='store_true')
    parser.add_argument('--receipt', type=Path)
    args = parser.parse_args()
    if args.apply and args.receipt is None:
        parser.error('--apply requires a fresh --receipt')
    plan = json.loads((BASE / 'promotion.json').read_text())
    for row in plan['evidence'] + plan['unchangedControls']:
        check_file(row)
    payloads = []
    for row in plan['files']:
        destination = Path(row['destination'])
        if os.path.lexists(destination):
            raise ValueError('Addition destination is no longer absent: ' + str(destination))
        payloads.append((row, check_file(row, 'source')))
    if not args.apply:
        print(json.dumps({'ready': True, 'additions': len(payloads),
                          'unchangedControls': len(plan['unchangedControls']), 'mainMutated': False}))
        return
    receipt = args.receipt.open('x', encoding='utf8')
    result = {'created': [], 'completed': False, 'existingSourceMutationAllowed': False}
    try:
        for row, raw in payloads:
            destination = Path(row['destination'])
            descriptor = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o644)
            try:
                remaining = memoryview(raw)
                while remaining:
                    written = os.write(descriptor, remaining)
                    if written <= 0:
                        raise OSError('No progress writing addition')
                    remaining = remaining[written:]
                os.fsync(descriptor)
            finally:
                os.close(descriptor)
            result['created'].append(str(destination))
            check_file(dict(row, path=str(destination)))
        for row in plan['unchangedControls']:
            check_file(row)
        result['completed'] = True
    except BaseException as error:
        result['failure'] = type(error).__name__ + ': ' + str(error)
        raise
    finally:
        receipt.write(json.dumps(result, indent=2, sort_keys=True) + '\n')
        receipt.flush()
        os.fsync(receipt.fileno())
        receipt.close()


if __name__ == '__main__':
    main()
