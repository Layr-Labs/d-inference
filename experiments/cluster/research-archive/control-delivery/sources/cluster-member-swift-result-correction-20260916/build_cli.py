"""Only the original matching CLI build, gated by corrected actual-test evidence."""
import argparse
import json
import os
import resource
from pathlib import Path
from context import (PACKAGE, RETRY, UPSTREAM_SHA, sha, save, isolated_environment,
                     recheck_current_sources, run_owned)
from qualification import expected_receipt


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--qualification', type=Path, required=True)
    parser.add_argument('--qualification-sha256', required=True)
    parser.add_argument('--attempt', type=int, required=True)
    args = parser.parse_args()
    if not 1 <= args.attempt <= 9:
        raise ValueError('Expected bounded attempt 1...9')
    qualified = args.qualification.resolve(strict=True)
    if (qualified.parent.parent != PACKAGE or qualified.name != 'checks.json'
            or qualified.parent.name not in ['qualification-' + str(i) for i in range(1, 10)]
            or sha(qualified) != args.qualification_sha256
            or json.loads(qualified.read_text()) != expected_receipt()):
        raise ValueError('Exact corrected qualification receipt required')
    workspace = recheck_current_sources()
    output = RETRY / ('swift-build-corrected-parser-' + str(args.attempt))
    output.mkdir(mode=0o700, exist_ok=False)
    command = ['swift', 'build', '-j', '2', '--disable-automatic-resolution',
               '--disable-build-manifest-caching', '--product', 'darkbloom']
    os.chdir(workspace / 'provider-swift')
    isolated_environment()
    old_limit = resource.getrlimit(resource.RLIMIT_FSIZE)
    resource.setrlimit(resource.RLIMIT_FSIZE, (512 * 1024 * 1024, old_limit[1]))
    try:
        run_owned(command, output, 'execution', 900)
    finally:
        resource.setrlimit(resource.RLIMIT_FSIZE, old_limit)
        recheck_current_sources()
        if sha(qualified) != args.qualification_sha256 or json.loads(qualified.read_text()) != expected_receipt():
            raise ValueError('Corrected qualification evidence changed during CLI build')
        save(output / 'source-recheck.json', {'sourcePinsUnchanged': True, 'mainUnchanged': True})
    binary = workspace / 'provider-swift/.build/debug/darkbloom'
    details = {'binarySHA256': sha(binary), 'binaryBytes': binary.stat().st_size, 'executedBinary': False}
    save(output / 'checks.json', {'passed': True, 'phase': 'swift-build', 'details': details,
        'sourcePinsUnchanged': True, 'mainChanged': False, 'modelOrRemoteExecuted': False,
        'ownerKeyGrantQualified': False, 'executionSHA256': sha(output / 'execution.json'),
        'originalWrapperManifestSHA256': UPSTREAM_SHA,
        'correctionManifestSHA256': sha(PACKAGE / 'manifest.json'),
        'correctedQualificationSHA256': args.qualification_sha256,
        'candidateSourceSHA256': sha(RETRY / 'candidate-before.json')})
    print(json.dumps(details, sort_keys=True))


if __name__ == '__main__':
    main()
