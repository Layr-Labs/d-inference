"""One explicit private owner run after a collected fresh same-build reference."""
import argparse
import json
from pathlib import Path
import sys

from common import local_execute, sha, verify_bound, verify_sources, write_json
from results import copies, parent, pinned_json, reference_result
from audit_common import exact


def main():
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument('--bound', required=True, type=Path)
    parser.add_argument('--binding-sha256', required=True)
    parser.add_argument('--mode', required=True, choices=['off','depth1'])
    parser.add_argument('--reference-result', required=True, type=Path)
    parser.add_argument('--reference-result-sha256', required=True)
    for rank in [0,1]:
        parser.add_argument('--copy' + str(rank), required=True, type=Path)
        parser.add_argument('--copy' + str(rank) + '-sha256', required=True)
    parser.add_argument('--off-result', type=Path)
    parser.add_argument('--off-result-sha256')
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args(); verify_sources(); verify_bound(args.bound, args.binding_sha256)
    binding = json.loads((args.bound / 'expected.json').read_bytes())
    reference = reference_result(args.reference_result, args.reference_result_sha256, binding)
    copies([args.copy0,args.copy1], [args.copy0_sha256,args.copy1_sha256], args.binding_sha256)
    if args.mode == 'depth1':
        if args.off_result is None or args.off_result_sha256 is None:
            raise ValueError('Depth1 requires actual off numerical and physical completion first')
        off = pinned_json(args.off_result, args.off_result_sha256)
        for key, wanted in dict(schema='qwen_mtp_owned_pair_result_v1', status='passed', mode='off',
            bindingSHA256=args.binding_sha256, referenceResultSHA256=args.reference_result_sha256,
            selectedTokenIDs=reference['selectedTokenIDs'], exactReferenceNumericalComparisonPassed=True,
            ownedCleanupAndAliasVerified=True).items():
            exact(off.get(key), wanted, 'Actual off prerequisite ' + key)
    elif args.off_result is not None or args.off_result_sha256 is not None:
        raise ValueError('Off cannot consume a prior off result')
    if not args.output.is_absolute() or args.output != args.output.resolve() or args.output.exists():
        raise ValueError('Fresh canonical action output required')
    args.output.mkdir(mode=0o700)
    execute = local_execute(args.bound)
    command = [sys.executable, '-B', str(args.bound / args.mode / 'run_physical.py')]
    code = execute(command, args.output, 'parent', 660, cap=4*1024**2)
    if code != 0:
        raise ValueError('Parent failed; retain and inspect actual cleanup observations')
    actual = args.bound / args.mode / 'physical-1/execution.json'
    pin = sha(actual); parent(actual, pin)
    verify_sources(); verify_bound(args.bound, args.binding_sha256)
    write_json(args.output / 'run-result.json', dict(schema='qwen_mtp_owned_pair_run_v1', status='passed', mode=args.mode,
        bindingSHA256=args.binding_sha256, referenceResultSHA256=args.reference_result_sha256,
        offResultSHA256=args.off_result_sha256, parentExecution=str(actual), parentExecutionSHA256=pin,
        outerExecutionSHA256=sha(args.output / 'parent.execution.json'), numericalComparisonPerformed=False))


if __name__ == '__main__':
    main()
