"""Write an additive parser qualification, preserving the original refusal."""
import argparse
import json
from context import PACKAGE, save, sha
from qualification import expected_receipt


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--attempt', type=int, required=True)
    args = parser.parse_args()
    if not 1 <= args.attempt <= 9:
        raise ValueError('Expected bounded attempt 1...9')
    receipt = expected_receipt()
    output = PACKAGE / ('qualification-' + str(args.attempt))
    output.mkdir(mode=0o700, exist_ok=False)
    save(output / 'checks.json', receipt)
    print(json.dumps({'checks': str(output / 'checks.json'), 'sha256': sha(output / 'checks.json'),
                      'details': receipt['details']}, sort_keys=True))


if __name__ == '__main__':
    main()
