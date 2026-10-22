"""One test-only same-cache correction; reuse the actual qualified helper-2."""
import argparse
import ast
import json
import os
from pathlib import Path
import resource
import sys

BASE = Path(__file__).resolve().parent
PRIOR = BASE.parent / 'cluster-native-numerical-provider-build-draft-20260917'
sys.dont_write_bytecode = True
sys.path.insert(0, str(PRIOR))
import guards as prior
from activation import require_activation
from check_process import run_owned
from context import WORKSPACE, OUTPUT, SOURCE, SWIFT_FILTER, isolated_environment
from coverage import validate


def inputs():
    manifest = BASE / 'manifest.json'
    if manifest.exists():
        for row in json.loads(manifest.read_bytes())['files']:
            path = BASE / row['path']
            prior.require(path.is_file() and not path.is_symlink() and path.stat().st_size == row['bytes']
                          and prior.sha(path) == row['sha256'], 'Fixture successor changed')
    for row in json.loads((BASE / 'parent-pins.json').read_bytes()):
        path = Path(row['path'])
        prior.require(path.is_file() and not path.is_symlink() and path.stat().st_size == row['bytes']
                      and prior.sha(path) == row['sha256'], 'Retained failed evidence/source changed')
    _, main, _, before = prior.verify()
    prior.require(before == json.loads((OUTPUT / 'candidate-before.json').read_bytes()), 'Actual prepared candidate differs')
    rows = json.loads((BASE / 'integration.json').read_bytes())['files']
    prior.require(len(rows) == 1, 'One test-file correction only')
    row = rows[0]
    prior.require(row['path'] == 'provider-swift/Tests/ProviderCoreTests/Coordinator/NativePairMember/NativePairSharedRequestTests.swift'
                  and before[row['path']]['sha256'] == row['beforeSHA256'], 'Actual test preimage differs')
    source = Path(row['sourcePath'])
    prior.require(not source.is_symlink() and source.stat().st_size == row['bytes']
                  and prior.sha(source) == row['afterSHA256'], 'Proposed fixture differs')
    after = dict(before)
    after[row['path']] = {'sha256': row['afterSHA256']}
    prior.require(len(after) == len(before) == 13859, 'Test-only inventory count changed')
    return row, main, before, after


def full_check(candidate, main):
    inputs()
    require_activation()
    prior.recheck_sources(candidate, main)
    prior.require_preserved_cli()
    # Its original candidate hash remains authoritative for production code;
    # this successor changes only the ProviderCore test path checked above.
    prior.require_helper(2)


def prepare():
    row, main, before, after = inputs()
    output = BASE / 'preparation-1'
    output.mkdir(mode=0o700)
    receipt = dict(passed=False, helperRebuilt=False, compilerExecuted=False)
    try:
        full_check(before, main)
        destination = WORKSPACE / row['path']
        prior.require(prior.sha(destination) == row['beforeSHA256'], 'Actual fixture changed')
        with (output / 'original.swift').open('xb') as stream:
            stream.write(destination.read_bytes())
        raw = Path(row['sourcePath']).read_bytes()
        temporary = destination.with_name(destination.name + '.numerical-fixture-new')
        with temporary.open('x+b') as stream:
            stream.write(raw); stream.flush(); os.fsync(stream.fileno())
            stream.seek(0)
            prior.require(stream.read() == raw and os.path.samestat(os.fstat(stream.fileno()), os.stat(temporary, follow_symlinks=False))
                          and prior.sha(destination) == row['beforeSHA256'], 'Fixture changed before replacement')
            os.replace(temporary, destination)
        full_check(after, main)
        prior.save(output / 'candidate-after.json', after)
        receipt.update(passed=True, manifestSHA256=prior.sha(BASE / 'manifest.json'),
                       candidateSHA256=prior.sha(output / 'candidate-after.json'),
                       originalFixtureSHA256=prior.sha(output / 'original.swift'),
                       helperReceiptSHA256=prior.sha(OUTPUT / 'helper-2/checks.json'))
    finally:
        prior.save(output / 'receipt.json', receipt)


def run(phase):
    row, main, _, candidate = inputs()
    prepared = BASE / 'preparation-1'
    record = json.loads((prepared / 'receipt.json').read_bytes())
    prior.require(record['passed'] is True and record['manifestSHA256'] == prior.sha(BASE / 'manifest.json')
                  and record['candidateSHA256'] == prior.sha(prepared / 'candidate-after.json')
                  and json.loads((prepared / 'candidate-after.json').read_bytes()) == candidate
                  and prior.sha(prepared / 'original.swift') == row['beforeSHA256']
                  and record['helperReceiptSHA256'] == prior.sha(OUTPUT / 'helper-2/checks.json'), 'Matching fixture preparation required')
    full_check(candidate, main)
    if phase == 'build':
        tests = BASE / 'tests-1'
        passed = json.loads((tests / 'checks.json').read_bytes())
        prior.require(passed['passed'] is True and passed['manifestSHA256'] == prior.sha(BASE / 'manifest.json')
                      and passed['candidateSHA256'] == record['candidateSHA256']
                      and passed['executionSHA256'] == prior.sha(tests / 'execution.json')
                      and passed['helperReceiptSHA256'] == record['helperReceiptSHA256'], 'Matching complete tests required')
        prior.require(validate((tests / 'execution.stdout').read_text() + '\n' + (tests / 'execution.stderr').read_text()) == passed['details'],
                      'Actual 117-method completion differs')
    out = BASE / (phase + '-1')
    out.mkdir(mode=0o700)
    isolated_environment()
    os.chdir(WORKSPACE / 'provider-swift')
    limit = resource.getrlimit(resource.RLIMIT_FSIZE)
    resource.setrlimit(resource.RLIMIT_FSIZE, (512 * 1024 * 1024, limit[1]))
    receipt = dict(passed=False, phase=phase, helperRebuilt=False, modelOrRemoteExecuted=False,
                   manifestSHA256=prior.sha(BASE / 'manifest.json'), candidateSHA256=record['candidateSHA256'],
                   helperReceiptSHA256=record['helperReceiptSHA256'])
    try:
        argv = ['swift', 'test' if phase == 'tests' else 'build', '-j', '2', '--disable-automatic-resolution', '--disable-build-manifest-caching']
        if phase == 'tests':
            evidence = out / 'owned-native-evidence'; evidence.mkdir(mode=0o700)
            os.environ['DARKBLOOM_NATIVE_MEMBER_FIXTURE'] = str(OUTPUT / 'helper-2/native-member-fixture')
            os.environ['DARKBLOOM_NATIVE_MEMBER_EVIDENCE'] = str(evidence)
            argv += ['--filter', SWIFT_FILTER]
        else:
            argv += ['--product', 'darkbloom']
        receipt['execution'] = run_owned(argv, out, 'execution', 900)
        if phase == 'tests':
            receipt['details'] = validate((out / 'execution.stdout').read_text() + '\n' + (out / 'execution.stderr').read_text())
        else:
            binary = WORKSPACE / 'provider-swift/.build/debug/darkbloom'
            prior.require(binary.is_file() and not binary.is_symlink(), 'Built CLI must be regular')
            receipt['details'] = dict(binarySHA256=prior.sha(binary), binaryBytes=binary.stat().st_size, binaryExecuted=False)
        full_check(candidate, main)
        receipt['passed'] = True
    finally:
        resource.setrlimit(resource.RLIMIT_FSIZE, limit)
        try:
            full_check(candidate, main)
        except BaseException:
            receipt['passed'] = False
            raise
        finally:
            if (out / 'execution.json').exists(): receipt['executionSHA256'] = prior.sha(out / 'execution.json')
            prior.save(out / 'checks.json', receipt)


def main():
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument('phase', choices=['source', 'prepare', 'tests', 'build'])
    phase = parser.parse_args().phase
    if phase == 'source':
        inputs(); ast.parse(Path(__file__).read_text())
        print('PASS one fixture source; production/helper unchanged; no workspace hash or compiler')
    elif phase == 'prepare': prepare()
    else: run(phase)


if __name__ == '__main__':
    os.umask(0o077)
    main()
