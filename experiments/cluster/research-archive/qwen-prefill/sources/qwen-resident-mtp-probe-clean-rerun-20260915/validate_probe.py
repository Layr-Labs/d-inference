#!/usr/bin/env python3
"""Compare future sidecars with the frozen policy; performs no network/model work."""
import argparse
import json
import os
from pathlib import Path
from probe_io import read_file, prospective
from probe_values import digest, parse_json, require
from probe_validation import compare


def audit(base, rank0, rank1, controller):
    policy, policy_sha, inputs = prospective(base)  # Verify policy before candidate access.
    request = parse_json(inputs['request.json'])
    expected = parse_json(inputs['configuration/expected-agreement.json'])
    require(expected['rankBuildSHA256'] == [policy['nativeBinarySHA256']] * 2, 'Native policy pin differs')
    raw_candidates = [read_file(path, 1_048_576) for path in (rank0, rank1)]
    raw_controller = read_file(controller, 4_194_304)
    records = [parse_json(line) for line in raw_controller.splitlines() if line.strip()]
    result = compare(request, expected, [parse_json(raw) for raw in raw_candidates], records,
                     digest(inputs['configuration/controller.json']))
    result['prospectivePolicySHA256'] = policy_sha
    result['inputSHA256'] = dict(rank0=digest(raw_candidates[0]), rank1=digest(raw_candidates[1]), controller=digest(raw_controller))
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--rank0', type=Path, required=True)
    parser.add_argument('--rank1', type=Path, required=True)
    parser.add_argument('--controller', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    result = {'schema': 'private_registered_mtp_probe_comparison_v1', 'status': 'failed'}
    try:
        result = audit(Path(__file__).resolve().parent, args.rank0, args.rank1, args.controller)
    except Exception as error:
        result['errorType'] = type(error).__name__
        result['error'] = str(error)
    fd = os.open(args.output, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'w') as output:
        json.dump(result, output, sort_keys=True, indent=2, allow_nan=False); output.write('\n')
        output.flush(); os.fsync(output.fileno())
    print(json.dumps({'status': result['status'], 'outputSHA256': digest(args.output.read_bytes())}))
    return 0 if result['status'] == 'passed' else 1


if __name__ == '__main__':
    raise SystemExit(main())
