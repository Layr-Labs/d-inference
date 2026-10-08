"""One bounded native build, then pure argument/catalog checks; no GPU mode."""
import json
import os
import re
import sys
from pathlib import Path
from build_inputs import BASE, WORKSPACE, SCRATCH, inputs, sha
from verify_build_inputs import verify
from check_process import run_owned

PRODUCT = 'CollectiveAllocationCheck'


def expected_cases():
    v, _, _, _, _ = inputs()
    schedule = json.loads((Path(v['probe']) / 'PROBE-SCHEDULE.json').read_bytes())
    rows = [dict(id=x['id'], byteCounts=[g['bytes'] for g in x['geometries']],
                 primingByteCounts=[g['bytes'] for g in x['priming']],
                 rounds=x['rounds'], failure=x['failure']) for x in schedule['cases']]
    if len(rows) != 35 or len({x['id'] for x in rows}) != 35:
        raise ValueError('Wrong frozen allocation catalog')
    return rows


def main():
    if len(sys.argv) != 2 or not re.fullmatch(r'[A-Za-z0-9_-]+', sys.argv[1]):
        raise ValueError('One fresh relative attempt name required')
    out = BASE / sys.argv[1]
    out.mkdir(mode=0o700)
    receipt = dict(sourceSnapshotSHA256=sha(BASE / 'source-snapshot-1.json'),
                   dependencySnapshotSHA256=sha(BASE / 'dependency-snapshot-1.json'),
                   steps=[], product=PRODUCT, status='started',
                   nativeFixtureExecuted=False, modelExecuted=False, remoteExecuted=False)
    print('Allocation composed build runner PID ' + str(os.getpid()), flush=True)
    try:
        receipt['before'] = verify()
        args = ['swift', 'build', '--package-path', str(WORKSPACE / 'libs/darkbloom-cluster-worker'),
                '--scratch-path', str(SCRATCH), '-c', 'release', '--jobs', '2',
                '--disable-automatic-resolution', '--skip-update', '--disable-build-manifest-caching',
                '--triple', 'arm64-apple-macosx26.2', '-Xcc', '-target', '-Xcc', 'arm64-apple-macosx26.2',
                '-Xswiftc', '-DCOLLECTIVE_RECORD_ALLOCATION_CHECK', '--product', PRODUCT]
        receipt['steps'].append(run_owned(args, out, 'build', 900))
        verify()
        binary = SCRATCH / 'arm64-apple-macosx/release' / PRODUCT
        receipt['steps'].append(run_owned(['xcrun', 'vtool', '-show-build', str(binary)], out, 'version', 10))
        version = (out / 'version.stdout').read_text()
        if (version.count('LC_BUILD_VERSION') != 1 or 'platform MACOS' not in version or
                not any(line.split() == ['minos', '26.2'] for line in version.splitlines())):
            raise ValueError('Wrong native build target')
        receipt['steps'].append(run_owned([str(binary), 'check-arguments'], out, 'arguments', 10))
        if json.loads((out / 'arguments.stdout').read_bytes()) != {'argumentsAccepted': True, 'nativeExecuted': False}:
            raise ValueError('Pure argument mode differs')
        receipt['steps'].append(run_owned([str(binary), 'list-cases'], out, 'cases', 10))
        if json.loads((out / 'cases.stdout').read_bytes()) != expected_cases():
            raise ValueError('Native pure catalog differs from frozen 35-case schedule')
        receipt['binary'] = dict(path=str(binary), sha256=sha(binary), bytes=binary.stat().st_size)
        receipt['catalog'] = dict(count=35, stdoutSHA256=sha(out / 'cases.stdout'))
        receipt['status'] = 'passed'
    except BaseException as error:
        receipt['status'] = 'failed'
        receipt['failure'] = type(error).__name__ + ': ' + str(error)
        raise
    finally:
        try:
            receipt['after'] = verify()
        except BaseException as error:
            receipt['status'] = 'failed'
            receipt['sourceRecheckFailure'] = type(error).__name__ + ': ' + str(error)
        (out / 'receipt.json').write_text(json.dumps(receipt, indent=2, sort_keys=True) + '\n')
    if receipt['status'] != 'passed':
        raise ValueError('Post-build source verification failed')
    print('Allocation build and 35-case pure catalog PASS; no GPU execution', flush=True)


if __name__ == '__main__':
    os.umask(0o077)
    main()
