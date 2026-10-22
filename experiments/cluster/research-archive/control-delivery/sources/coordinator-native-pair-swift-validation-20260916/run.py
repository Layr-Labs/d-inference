"""One bounded granted Swift validation phase; retain all failures and sources."""
import argparse
import json
import os
from pathlib import Path
import resource
import sys
sys.dont_write_bytecode = True
import source_inventory as inventory
from check_process import run_owned
from guards import sha, save, verify_overlay, isolated_environment
from inputs import BASE, SOURCE, OVERLAY_SHA, B_OVERLAY_SHA, SWIFT_FILTER
from swift_results import validate_swift_results


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--phase', choices=['swift-build', 'swift-tests'], required=True)
    parser.add_argument('--prepared', type=Path, required=True)
    parser.add_argument('--attempt', type=int, required=True)
    args = parser.parse_args()
    if args.attempt < 1:
        raise ValueError('Invalid attempt')
    prepared = args.prepared.resolve(); workspace = prepared / 'workspace'
    preparation = json.loads((prepared / 'preparation.json').read_text())
    if (preparation['overlayManifestSHA256'] != OVERLAY_SHA or preparation['nativeBManifestSHA256'] != B_OVERLAY_SHA
            or preparation['wrapperManifestSHA256'] != sha(BASE / 'manifest.json')
            or preparation['swiftIntegrationSHA256'] != sha(BASE / 'swift-integration.json')
            or preparation['workspace'] != str(workspace) or preparation['source'] != str(SOURCE)
            or preparation['phase'] != 'swift'):
        raise ValueError('Prepared source identity differs')
    before = json.loads((prepared / 'source-before.json').read_text())
    candidate = json.loads((prepared / 'candidate-before.json').read_text())
    def recheck():
        integration = verify_overlay()
        expected = dict(before)
        for row in integration['files']:
            expected[row['path']] = {'sha256': row['proposedSHA256']}
        if expected != candidate or inventory.inventory(workspace) != candidate or inventory.inventory(SOURCE) != before:
            raise ValueError('MAIN or private Swift source/dependencies changed')
    recheck()
    if args.phase == 'swift-build':
        prior = prepared / ('swift-tests-' + str(args.attempt))
        checks = json.loads((prior / 'checks.json').read_text())
        if (checks.get('passed') is not True or checks.get('wrapperManifestSHA256') != sha(BASE / 'manifest.json')
                or checks.get('candidateSourceSHA256') != sha(prepared / 'candidate-before.json')
                or checks.get('details', {}).get('nativePairMethodsPassed') != 2
                or checks.get('executionSHA256') != sha(prior / 'execution.json')):
            raise ValueError('Matching member/native Swift test pass required before CLI build')
    output = prepared / (args.phase + '-' + str(args.attempt)); output.mkdir(mode=0o700, exist_ok=False)
    command = ['swift', 'build' if args.phase == 'swift-build' else 'test', '-j', '2',
               '--disable-automatic-resolution', '--disable-build-manifest-caching']
    command += ['--product', 'darkbloom'] if args.phase == 'swift-build' else ['--filter', SWIFT_FILTER]
    os.chdir(workspace / 'provider-swift')
    isolated_environment()
    old_limit = resource.getrlimit(resource.RLIMIT_FSIZE)
    resource.setrlimit(resource.RLIMIT_FSIZE, (512 * 1024 * 1024, old_limit[1]))
    try:
        run_owned(command, output, 'execution', 900)
    finally:
        resource.setrlimit(resource.RLIMIT_FSIZE, old_limit)
        recheck()
        save(output / 'source-recheck.json', {'sourcePinsUnchanged': True, 'mainUnchanged': True})
    if args.phase == 'swift-build':
        binary = workspace / 'provider-swift/.build/debug/darkbloom'
        details = {'binarySHA256': sha(binary), 'binaryBytes': binary.stat().st_size, 'executedBinary': False}
    else:
        combined = (output / 'execution.stdout').read_text() + '\n' + (output / 'execution.stderr').read_text()
        details = validate_swift_results(combined)
    save(output / 'checks.json', {'passed': True, 'phase': args.phase, 'details': details,
        'sourcePinsUnchanged': True, 'mainChanged': False, 'modelOrRemoteExecuted': False,
        'ownerKeyGrantQualified': False, 'executionSHA256': sha(output / 'execution.json'),
        'wrapperManifestSHA256': sha(BASE / 'manifest.json'),
        'candidateSourceSHA256': sha(prepared / 'candidate-before.json')})
    print(json.dumps(details, sort_keys=True))


if __name__ == '__main__':
    main()
