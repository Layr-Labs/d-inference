"""One bounded granted validation phase; failures and exact sources remain intact."""
import argparse
import json
import os
from pathlib import Path
import re
import resource
import sys
sys.dont_write_bytecode = True
import source_inventory as inventory
from check_process import run_owned
from guards import sha, save, verify_overlay, verify_go, isolated_environment
from inputs import SOURCE, OVERLAY_SHA, GO, GO_SHA, GO_PACKAGES, GO_FILTER, SWIFT_FILTER

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--phase', choices=['go-focused', 'go-all', 'swift-build', 'swift-tests'], required=True)
    parser.add_argument('--prepared', type=Path, required=True)
    parser.add_argument('--attempt', type=int, required=True)
    args = parser.parse_args()
    if args.attempt < 1:
        raise ValueError('Invalid attempt')
    prepared = args.prepared.resolve(); workspace = prepared / 'workspace'
    preparation = json.loads((prepared / 'preparation.json').read_text())
    if preparation['overlayManifestSHA256'] != OVERLAY_SHA or preparation['workspace'] != str(workspace):
        raise ValueError('Prepared source identity differs')
    go = args.phase.startswith('go-')
    if preparation['phase'] != ('go' if go else 'swift'):
        raise ValueError('Wrong preparation phase')
    before = json.loads((prepared / 'source-before.json').read_text())
    candidate = None if go else json.loads((prepared / 'candidate-before.json').read_text())
    def recheck():
        verify_overlay()
        if go:
            verify_go(before, workspace)
        elif inventory.inventory(workspace) != candidate or inventory.inventory(SOURCE) != before:
            raise ValueError('MAIN or private Swift source/dependencies changed')
    recheck()
    output = prepared / (args.phase + '-' + str(args.attempt)); output.mkdir(mode=0o700, exist_ok=False)
    if go:
        if sha(Path(GO)) != GO_SHA:
            raise ValueError('Go toolchain changed')
        command = [GO, 'test', '-json', '-race', '-p', '2', '-count=1', '-timeout=120s']
        if args.phase == 'go-focused': command += ['-run', GO_FILTER]
        command += ['./' + p for p in GO_PACKAGES]
        timeout = 300
        os.chdir(workspace)
    else:
        command = ['swift', 'build' if args.phase == 'swift-build' else 'test', '-j', '2',
                   '--disable-automatic-resolution', '--disable-build-manifest-caching']
        command += ['--product', 'darkbloom'] if args.phase == 'swift-build' else ['--filter', SWIFT_FILTER]
        timeout = 900
        os.chdir(workspace / 'provider-swift')
    isolated_environment()
    old_limit = resource.getrlimit(resource.RLIMIT_FSIZE)
    resource.setrlimit(resource.RLIMIT_FSIZE, (512 * 1024 * 1024, old_limit[1]))
    try:
        result = run_owned(command, output, 'execution', timeout)
    finally:
        resource.setrlimit(resource.RLIMIT_FSIZE, old_limit)
        recheck()
        save(output / 'source-recheck.json', {'sourcePinsUnchanged': True, 'mainUnchanged': True})
    stdout = (output / 'execution.stdout').read_text()
    stderr = (output / 'execution.stderr').read_text()
    details = {}
    if go:
        events = [json.loads(line) for line in stdout.splitlines() if line]
        packages = {'github.com/eigeninference/d-inference/' + p for p in GO_PACKAGES}
        complete = {e.get('Package') for e in events if e.get('Action') == 'pass' and 'Test' not in e}
        passed = {(e['Package'], e['Test']) for e in events if e.get('Action') == 'pass' and 'Test' in e and '/' not in e['Test']}
        verified = {t for _, t in passed if t.startswith('TestVerifiedPair')}
        member = {t for _, t in passed if t.startswith(('TestClusterMember', 'TestMemberRole'))}
        if not packages.issubset(complete) or len(verified) != 15 or len(member) != 4:
            raise ValueError('Go package/test completion is incomplete')
        details = {'verifiedPairMethods': len(verified), 'memberMethods': len(member), 'totalMethods': len(passed),
                   'apiHandlerPackageCompiled': True, 'apiTestsSelected': args.phase == 'go-all', 'raceDetector': True}
    elif args.phase == 'swift-build':
        binary = workspace / 'provider-swift/.build/debug/darkbloom'
        details = {'binarySHA256': sha(binary), 'binaryBytes': binary.stat().st_size, 'executedBinary': False}
    else:
        combined = stdout + '\n' + stderr
        for name in ['legacyOmissionAndMemberInventorySurviveRawAttestation', 'realSocketRoleNegotiation',
                     'staleNegotiationTimerCannotRefuseReplacement', 'acceptedLeaderControlLossLatchesStopBeforeReconnect',
                     'memberRoleSelectionAndExplicitCoordinatorParseWithoutIO']:
            if name not in combined:
                raise ValueError('Required member/CLI case absent: ' + name)
        match = re.search(r'Test run with (\d+) tests?[^\n]*passed', combined)
        if not match:
            raise ValueError('Swift Testing completion summary absent')
        details = {'testsPassed': int(match.group(1)), 'filter': SWIFT_FILTER, 'realSocketCasesIncluded': True}
    save(output / 'checks.json', {'passed': True, 'phase': args.phase, 'details': details,
        'sourcePinsUnchanged': True, 'mainChanged': False, 'modelOrRemoteExecuted': False,
        'ownerKeyGrantQualified': False, 'executionSHA256': sha(output / 'execution.json')})
    print(json.dumps(details, sort_keys=True))

if __name__ == '__main__':
    main()
