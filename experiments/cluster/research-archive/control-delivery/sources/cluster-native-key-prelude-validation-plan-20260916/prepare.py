"""Create only the exact reviewed small native-prelude validation source tree.
No compiler, crypto/vector execution, process launch, cache or network operation.
Run preparation only when root grants its scheduled materialization/CPU slot.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import sys
sys.dont_write_bytecode = True

HERE = Path(__file__).resolve().parent
RESEARCH = HERE.parent
BASE = RESEARCH / 'cluster-native-key-prelude-draft-20260916'
CORRECTION = RESEARCH / 'cluster-native-key-prelude-fixture-correction-20260916'
BASE_SHA = '23fce2b652fac6a42eda424cb83beb425cfd90f2482eca022e9f89c23f105afb'
CORRECTION_SHA = 'c96e6e0a8a8fb0db5f05bcdcba7c4759cc218035da478dacb134195ee5ef767c'
FIXTURE = 'Tests/NativeKeyChild.swift'
BEFORE = 'd5cc458ba093135ee582b420abc3168aadc71f975238277f1fbd01b643436d41'
AFTER = 'f8380b8e3813124e19313a6fc0184b5602ff918cebe3b5dc6ec3106ea9202331'


def digest(raw): return hashlib.sha256(raw).hexdigest()
def encoded(value): return (json.dumps(value, indent=2, sort_keys=True) + '\n').encode()

def safe_relative(value):
    path = PurePosixPath(value)
    if not value or path.is_absolute() or path.as_posix() != value or any(x in ('.', '..') for x in path.parts):
        raise ValueError('Invalid frozen member path')
    return value


def regular_bytes(path, maximum=1_048_576):
    if path.is_symlink() or not path.is_file() or path.stat().st_size > maximum:
        raise ValueError('Expected bounded regular input: ' + str(path))
    raw = path.read_bytes()
    if len(raw) > maximum: raise ValueError('Input grew beyond bound')
    return raw


def read_frozen(directory, manifest_sha, expected_count):
    manifest_bytes = regular_bytes(directory / 'manifest.json')
    if digest(manifest_bytes) != manifest_sha: raise ValueError('Frozen manifest differs')
    rows = json.loads(manifest_bytes)['files']
    if len(rows) != expected_count: raise ValueError('Frozen member count differs')
    files = {}
    for row in rows:
        relative = safe_relative(row['path'])
        if relative in files or relative == 'manifest.json': raise ValueError('Duplicate/reserved frozen member')
        raw = regular_bytes(directory / relative)
        if len(raw) != row['bytes'] or digest(raw) != row['sha256']: raise ValueError('Frozen member differs: ' + relative)
        files[relative] = raw
    return manifest_bytes, files


def build_plan():
    base_manifest, files = read_frozen(BASE, BASE_SHA, 46)
    correction_manifest, correction = read_frozen(CORRECTION, CORRECTION_SHA, 6)
    integration = json.loads(correction['integration.json'])
    expected_change = {'path': FIXTURE, 'beforeSHA256': BEFORE, 'afterSHA256': AFTER}
    if integration['baseManifestSHA256'] != BASE_SHA or integration['changes'] != [expected_change] or integration['runtimeChanges'] != []:
        raise ValueError('Fixture correction scope differs')
    if digest(files[FIXTURE]) != BEFORE or digest(correction['originals/' + FIXTURE]) != BEFORE:
        raise ValueError('Fixture preimage differs')
    replacement = correction['proposed/' + FIXTURE]
    if digest(replacement) != AFTER: raise ValueError('Corrected fixture differs')
    original_runtime = {p: digest(raw) for p, raw in files.items() if p.startswith('proposed/')}
    if len(original_runtime) != 9: raise ValueError('Runtime source scope differs')
    for row in json.loads(files['dependency-pins.json']):
        if digest(files[row['snapshot']]) != row['sha256'] or digest(regular_bytes(Path(row['source']))) != row['sha256']:
            raise ValueError('Reviewed dependency source/copy differs')
    files[FIXTURE] = replacement
    combination = {'schema': 'darkbloom_native_key_prelude_combination_v1',
        'baseManifestSHA256': BASE_SHA, 'fixtureCorrectionManifestSHA256': CORRECTION_SHA,
        'changes': [expected_change], 'runtimeSourceSHA256': original_runtime,
        'runnerSHA256': digest(files['Tests/run.py']), 'ownedHelperSHA256': digest(files['Tests/owned_process.py']),
        'baseMemberCount': 46, 'correctionMemberCount': 6, 'runtimeChanges': [],
        'modelExecuted': False, 'cryptoExecuted': False, 'compiled': False}
    provenance = {
        'provenance/prelude-A-manifest.json': base_manifest,
        'provenance/fixture-correction-manifest.json': correction_manifest,
        'provenance/fixture-correction.patch': correction['fixture.patch'],
        'provenance/combination.json': encoded(combination),
    }
    if files.keys() & provenance.keys(): raise ValueError('Provenance path collision')
    files.update(provenance)
    if len(files) != 50 or sum(map(len, files.values())) > 524_288: raise ValueError('Unexpected source-copy scope')
    if {p: digest(raw) for p, raw in files.items() if p.startswith('proposed/')} != original_runtime:
        raise ValueError('Runtime changed')
    manifest = {'schema': 'darkbloom_native_key_prelude_corrected_validation_source_v1',
        'files': [{'path': p, 'bytes': len(raw), 'sha256': digest(raw)} for p, raw in sorted(files.items())],
        'baseManifestSHA256': BASE_SHA, 'fixtureCorrectionManifestSHA256': CORRECTION_SHA}
    return files, encoded(manifest), combination


def verify_tree(source, files, manifest_bytes):
    expected = set(files) | {'manifest.json'}
    actual = set()
    for path in source.rglob('*'):
        if path.is_symlink(): raise ValueError('Unexpected combined symlink')
        if path.is_file(): actual.add(path.relative_to(source).as_posix())
    if actual != expected: raise ValueError('Combined source member set differs')
    for relative, raw in files.items():
        if regular_bytes(source / relative) != raw: raise ValueError('Combined member differs: ' + relative)
    if regular_bytes(source / 'manifest.json') != manifest_bytes: raise ValueError('Combined manifest differs')


def main():
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    files, manifest_bytes, combination = build_plan()
    if regular_bytes(HERE / 'expected-combined-manifest.json') != manifest_bytes:
        raise ValueError('Reviewed combined manifest differs')
    # Keep all copied sources outside both immutable input folders and MAIN.
    requested = args.output.absolute()
    if requested.parent.resolve() != RESEARCH.resolve() or requested.name in {BASE.name, CORRECTION.name, HERE.name}:
        raise ValueError('Use a fresh direct child of the research directory')
    output = requested.parent.resolve() / requested.name
    output.mkdir(mode=0o700, exist_ok=False)
    try:
        source = output / 'source'; source.mkdir(mode=0o700)
        for relative, raw in sorted(files.items()):
            path = source / relative; path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            with path.open('xb') as stream: stream.write(raw)
        with (source / 'manifest.json').open('xb') as stream: stream.write(manifest_bytes)
        verify_tree(source, files, manifest_bytes)
        after_files, after_manifest, _ = build_plan()
        if after_files != files or after_manifest != manifest_bytes: raise ValueError('Original inputs changed during copy')
        receipt = {'source': str(source), 'sourceMembers': len(files), 'totalFilesIncludingManifest': len(files) + 1,
            'sourceBytesExcludingManifest': sum(map(len, files.values())), 'combinedManifestSHA256': digest(manifest_bytes),
            'combination': combination, 'originalInputsUnchanged': True, 'cacheCopied': False,
            'compilerRun': False, 'cryptoExecuted': False, 'remoteAccess': False}
        with (output / 'preparation.json').open('xb') as stream: stream.write(encoded(receipt))
        print(json.dumps(receipt, sort_keys=True))
    except BaseException as error:
        try:
            with (output / 'preparation-failure.json').open('xb') as stream:
                stream.write(encoded({'passed': False, 'failureType': type(error).__name__, 'partialTreeRetained': True}))
        except OSError: pass
        raise


if __name__ == '__main__':
    os.umask(0o077)
    main()
