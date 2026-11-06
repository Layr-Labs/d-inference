"""Reuse the original qualified binder with only its explicit retry-job expectation."""
import argparse
import importlib.util
import os
import sys
from retry_inputs import BASE, EXPERIMENT, INPUTS, REFERENCE, expected_packet, verify_prepared


def main():
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument('--native-attempt', type=int, required=True)
    parser.add_argument('--cpu-attempt', type=int, required=True)
    parser.add_argument('--reference-review', required=True)
    parser.add_argument('--reference-review-sha256', required=True)
    args = parser.parse_args()
    verify_prepared()
    sys.dont_write_bytecode = True
    sys.path.insert(0, str(EXPERIMENT))
    spec = importlib.util.spec_from_file_location('qualified_c256_case_binder', EXPERIMENT/'bind_cases.py')
    qualified = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(qualified)
    # Only the expected reference packet changes, by two pinned historical paths.
    # BASE/DRAFT/BUILD, source checks, actual CPU/native/argument proofs, reference
    # contract, resource capacity, case construction and cleanup helpers stay original.
    qualified.expected_packet = expected_packet
    sys.argv = [str(EXPERIMENT/'bind_cases.py'), '--inputs', str(INPUTS),
        '--native-attempt', str(args.native_attempt), '--cpu-attempt', str(args.cpu_attempt),
        '--reference-returned', str(REFERENCE/'physical-collect-1/returned'),
        '--reference-review', args.reference_review, '--reference-review-sha256', args.reference_review_sha256]
    qualified.main()
    verify_prepared()


if __name__ == '__main__':
    os.umask(0o077)
    main()
