"""Extract registered Qwen services or explicitly project them to two devices."""

import argparse
import json
import sys

from .packet import extract
from .projection import assumed_profile
from .catalog import associate_packet


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('packet', help='Pinned file references and externally supplied provenance')
    output = parser.add_mutually_exclusive_group()
    output.add_argument('--assume-independent-devices', nargs=2, metavar=('PRODUCER', 'CONSUMER'),
                        help='Emit an assumed cost profile with unknown transport and memory costs')
    output.add_argument('--catalog', help='Associate observations with a native candidate catalog')
    parser.add_argument('--catalog-sha256', help='Required raw byte pin for --catalog')
    parser.add_argument('--policy', choices=('serial_v1', 'prompt_lookahead_one_v1'),
                        help='Modeled policy; requires --assume-independent-devices')
    args = parser.parse_args()
    if args.policy and not args.assume_independent_devices:
        parser.error('--policy requires --assume-independent-devices')
    if (args.catalog is None) != (args.catalog_sha256 is None):
        parser.error('--catalog and --catalog-sha256 are required together')
    if args.catalog is not None and (not args.catalog or not args.catalog_sha256):
        parser.error('--catalog and --catalog-sha256 must be nonempty')
    try:
        result = (associate_packet(args.packet, args.catalog, args.catalog_sha256)
                  if args.catalog is not None else extract(args.packet))
        if args.assume_independent_devices:
            result = assumed_profile(result, args.assume_independent_devices, args.policy)
        print(json.dumps(result, sort_keys=True, indent=2, allow_nan=False))
    except (OSError, ValueError, RecursionError) as error:
        print(f'Service extraction refused: {error}', file=sys.stderr)
        return 2
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
