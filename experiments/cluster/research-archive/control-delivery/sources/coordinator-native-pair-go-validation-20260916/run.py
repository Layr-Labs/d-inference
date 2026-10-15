"""One bounded granted Go phase; preserve actual failures and exact source pins."""
import argparse
import json
import os
from pathlib import Path
import resource
import sys
sys.dont_write_bytecode = True
from check_process import run_owned
from guards import sha, save, verify_overlay, verify_go, isolated_environment
from inputs import (BASE, SOURCE, OVERLAY_SHA, B_OVERLAY_SHA, CORRECTION_SHA,
                    GO, GO_SHA, GO_PACKAGES, GO_FILTER, NATIVE_PAIR_METHODS)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--phase', choices=['go-focused', 'go-all'], required=True)
    parser.add_argument('--prepared', type=Path, required=True)
    parser.add_argument('--attempt', type=int, required=True)
    args = parser.parse_args()
    if args.attempt < 1:
        raise ValueError('Invalid attempt')
    prepared = args.prepared.resolve(); workspace = prepared / 'workspace'
    if prepared.parent != BASE.parent or prepared == BASE or workspace.is_symlink():
        raise ValueError('Expected the private Go preparation sibling')
    preparation = json.loads((prepared / 'preparation.json').read_text())
    if (preparation['overlayManifestSHA256'] != OVERLAY_SHA or
        preparation.get('nativeOverlayManifestSHA256') != B_OVERLAY_SHA or
        preparation.get('correctionManifestSHA256') != CORRECTION_SHA or
        preparation['workspace'] != str(workspace) or preparation['source'] != str(SOURCE) or
        preparation['phase'] != 'go' or
        preparation['sourceInventorySHA256'] != sha(prepared / 'source-before.json')):
        raise ValueError('Prepared source identity differs')
    before = json.loads((prepared / 'source-before.json').read_text())

    def recheck():
        verify_overlay()
        verify_go(before, workspace)

    recheck()
    output = prepared / (args.phase + '-' + str(args.attempt)); output.mkdir(mode=0o700, exist_ok=False)
    if sha(Path(GO)) != GO_SHA:
        raise ValueError('Go toolchain changed')
    test_timeout = '180s' if args.phase == 'go-all' else '120s'
    command = [GO, 'test', '-json', '-race', '-p', '2', '-count=1', '-timeout=' + test_timeout]
    if args.phase == 'go-focused':
        command += ['-run', GO_FILTER]
    command += ['./' + p for p in GO_PACKAGES]
    os.chdir(workspace)
    isolated_environment()
    old_limit = resource.getrlimit(resource.RLIMIT_FSIZE)
    resource.setrlimit(resource.RLIMIT_FSIZE, (512 * 1024 * 1024, old_limit[1]))
    try:
        run_owned(command, output, 'execution', 300, diagnostic_limit=16_777_216)
    finally:
        resource.setrlimit(resource.RLIMIT_FSIZE, old_limit)
        recheck()
        save(output / 'source-recheck.json', {'sourcePinsUnchanged': True, 'mainUnchanged': True})
    stdout = (output / 'execution.stdout').read_text()
    events = [json.loads(line) for line in stdout.splitlines() if line]
    packages = {'github.com/eigeninference/d-inference/' + p for p in GO_PACKAGES}
    complete = {e.get('Package') for e in events if e.get('Action') == 'pass' and 'Test' not in e}
    passed = {(e['Package'], e['Test']) for e in events if e.get('Action') == 'pass' and 'Test' in e and '/' not in e['Test']}
    verified = {t for _, t in passed if t.startswith('TestVerifiedPair')}
    member = {t for _, t in passed if t.startswith(('TestClusterMember', 'TestMemberRole'))}
    native = {t for _, t in passed if t.startswith('TestNativePair')}
    if not packages.issubset(complete) or len(verified) != 15 or len(member) != 4 or native != NATIVE_PAIR_METHODS:
        raise ValueError('Go package/test completion is incomplete')
    details = {'verifiedPairMethods': len(verified), 'memberMethods': len(member),
               'nativePairMethods': len(native), 'nativePairPassed': sorted(native), 'totalMethods': len(passed),
               'apiHandlerPackageCompiled': True, 'apiTestsSelected': True, 'raceDetector': True}
    save(output / 'checks.json', {'passed': True, 'phase': args.phase, 'details': details,
        'sourcePinsUnchanged': True, 'mainChanged': False, 'modelOrRemoteExecuted': False,
        'providerNativeInvocationQualified': False, 'encryptedRDMAQualified': False,
        'executionSHA256': sha(output / 'execution.json')})
    print(json.dumps(details, sort_keys=True))


if __name__ == '__main__':
    main()
