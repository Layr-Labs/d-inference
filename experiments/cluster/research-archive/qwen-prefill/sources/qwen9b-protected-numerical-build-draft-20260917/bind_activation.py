"""Root-only binding of actual canonical PASS artifacts; no compiler or mutation."""
import argparse
import json
import os
from pathlib import Path
import re
from retry_inputs import BASE, OLD, OLD_SHA, NUMERICAL_SHA, SCRATCH, expected, sha
from check_results import require_tests
from validate_description import validate

def require(value, message):
    if not value: raise ValueError(message)

def comparison():
    source = BASE.parent / 'qwen9b-protected-numerical-evidence-root-review-20260917'
    bound = json.loads((BASE / 'qualified-comparison.json').read_bytes())
    for row in bound['files']:
        path = Path(row['path'])
        require(path.is_file() and not path.is_symlink() and path.stat().st_size == row['bytes'] and sha(path) == row['sha256'], 'Prior comparator evidence changed')
    record = json.loads((source/'comparator-receipt.json').read_bytes())
    child = json.loads((source/'comparator-controls.json').read_bytes())
    require(record['status'] == 'passed' and record['sourceManifestSHA256'] == NUMERICAL_SHA
        and record['comparatorMethods'] == 4 and record['fixtureOnly'] is True
        and record['actualReferenceRead'] is False and record['execution'] == child, 'Comparator qualification differs')
    require(child['exitCode'] == 0 and child['reaped'] and child['groupAbsent']
        and not child['timedOut'] and not child['killedOwnedGroup'], 'Comparator child did not naturally complete')
    require(not (source/'comparator-controls.stdout').read_bytes()
        and re.fullmatch(r'\.\.\.\.\n-+\nRan 4 tests in \d+\.\d+s\n\nOK\n',
            (source/'comparator-controls.stderr').read_text()) is not None, 'Actual four-method unittest output differs')
    return bound

def bind(bundle_sha, native_sha):
    for value in (bundle_sha, native_sha):
        require(len(value) == 64 and all(x in '0123456789abcdef' for x in value), 'Root must supply actual lowercase SHA256 pins')
    qualified = json.loads((BASE/'canonical-qualified.json').read_bytes())
    require(bundle_sha == qualified['bundleSHA256'] and native_sha == qualified['nativeSHA256'], 'Actual canonical pins differ from root-supplied source binding')
    expected(); comparison()
    require(sha(OLD/'source-snapshot-4.json') == qualified['sourceSnapshotSHA256']
        and sha(OLD/'dependency-snapshot-4.json') == qualified['dependencySnapshotSHA256'], 'Actual canonical snapshot identity differs')
    directory = OLD / 'runtime-bundle-4'
    require(sha(directory / 'bundle.json') == bundle_sha, 'Actual canonical bundle differs from root pin')
    bundle = json.loads((directory / 'bundle.json').read_bytes())
    require(bundle['nativeBinarySHA256'] == native_sha and bundle['servingEnabled'] is False
            and bundle['modelExecuted'] is False and bundle['remoteExecuted'] is False, 'Canonical artifact scope differs')
    pins = []
    def pin(path):
        require(path.is_file() and not path.is_symlink(), 'Regular canonical evidence required')
        pins.append(dict(path=str(path), bytes=path.stat().st_size, sha256=sha(path)))
    for name in ('manifest.json', 'source-snapshot-4.json', 'dependency-snapshot-4.json'): pin(OLD / name)
    pin(directory / 'bundle.json')
    expected_names = {'darkbloom-cluster-worker','mlx.metallib','mlx-swift-lm_MLXLMCommon.bundle/pagedattention.metal',
                      'ordinary-capability.json','protected-runtime-description.json','source-identity.json'}
    require({r['path'] for r in bundle['files']} == expected_names and len(bundle['files']) == 6, 'Canonical bundle members differ')
    for row in bundle['files']:
        path = directory / row['path']; pin(path)
        require(pins[-1]['bytes'] == row['bytes'] and pins[-1]['sha256'] == row['sha256'], 'Canonical bundle member changed')
    source_identity = json.loads((directory / 'source-identity.json').read_bytes())
    require(source_identity['sourceManifestSHA256'] == OLD_SHA and source_identity['wrapperManifestSHA256'] == OLD_SHA
            and source_identity['passedPhases'] == bundle['passedPhases'], 'Canonical source qualification differs')
    counts = {'source-snapshot-4.json': 3076, 'dependency-snapshot-4.json': 9832}
    for phase in ('runtime','worker','capability','native'):
        target = OLD / (phase + '-4')
        record = json.loads((target / 'receipt.json').read_bytes())
        require(record['status'] == 'passed' and record['phase'] == phase and record['sourceManifestSHA256'] == OLD_SHA
                and record['before'] == counts and record['after'] == counts, 'Canonical phase not complete')
        require(record['sourceSnapshotSHA256'] == sha(OLD / 'source-snapshot-4.json')
                and record['dependencySnapshotSHA256'] == sha(OLD / 'dependency-snapshot-4.json'), 'Canonical phase source mismatch')
        require(bundle['passedPhases'][phase] == dict(attempt=phase+'-4', receiptSHA256=sha(target/'receipt.json')), 'Canonical phase receipt changed')
        require(record['steps'] and all(s.get('exitCode') == 0 and s.get('reaped') and s.get('groupAbsent')
                and not s.get('timedOut') and not s.get('killedOwnedGroup') for s in record['steps']), 'Canonical child retirement incomplete')
        pin(target / 'receipt.json')
        for path in sorted(target.glob('*')):
            if path.suffix in ('.stdout','.stderr','.json') and path.name != 'receipt.json': pin(path)
        if phase in ('runtime','worker'):
            raw = (target/'tests.stdout').read_bytes() + (target/'tests.stderr').read_bytes()
            require(require_tests(raw, json.loads((OLD/'expected-tests.json').read_bytes())[phase]) == record['testResults'], 'Canonical test result mismatch')
        if phase == 'native':
            require(record['binary']['sha256'] == native_sha and record['description'] == bundle['description'], 'Canonical native identity mismatch')
    description = validate((directory/'ordinary-capability.json').read_bytes(),
        (directory/'protected-runtime-description.json').read_bytes(), native_sha, OLD/'description-contract.json')
    require(description == bundle['description'], 'Canonical description no longer validates')
    require(description['descriptorSHA256'] == qualified['descriptorSHA256']
        and description['resourcePolicySHA256'] == qualified['resourcePolicySHA256'], 'Root-observed canonical descriptor differs')
    for phase in ('controls','prepare','runtime','worker','capability','native','package'):
        path = OLD / ('root-'+phase+'-4/receipt.json'); record = json.loads(path.read_bytes()); pin(path)
        require(record['status'] == 'passed' and record['phase'] == phase and record['manifestSHA256'] == OLD_SHA, 'Canonical phase order incomplete')
    require(sha(SCRATCH/'arm64-apple-macosx/release/darkbloom-cluster-worker') == native_sha, 'Current cached native differs before activation')
    return dict(schema='numerical_build_activation_v1', wrapperManifestSHA256=sha(BASE/'manifest.json'),
        canonicalBundleSHA256=bundle_sha, canonicalNativeSHA256=native_sha, sourcePins=pins,
        description=description, compilerExecuted=False, materializationExecuted=False)

def activation():
    comparison()
    path = BASE / 'activation-1/activation.json'
    require(path.is_file() and not path.is_symlink(), 'Root must bind actual canonical artifacts first')
    value = json.loads(path.read_bytes())
    require(value['wrapperManifestSHA256'] == sha(BASE/'manifest.json'), 'Activation wrapper changed')
    for row in value['sourcePins']:
        path = Path(row['path'])
        require(path.is_file() and not path.is_symlink() and path.stat().st_size == row['bytes'] and sha(path) == row['sha256'], 'Bound canonical evidence changed')
    return value

def main():
    p=argparse.ArgumentParser(allow_abbrev=False)
    p.add_argument('--canonical-bundle-sha256',required=True);p.add_argument('--canonical-native-sha256',required=True)
    args=p.parse_args(); value=bind(args.canonical_bundle_sha256,args.canonical_native_sha256)
    directory=BASE/'activation-1';directory.mkdir(mode=0o700)
    with (directory/'activation.json').open('x') as stream:json.dump(value,stream,sort_keys=True,indent=2);stream.write('\n')
    print(json.dumps(dict(activationSHA256=sha(directory/'activation.json'),canonicalNativeSHA256=value['canonicalNativeSHA256'])))

if __name__=='__main__':
    os.umask(0o077);main()
