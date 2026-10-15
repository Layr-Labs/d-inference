"""Sequential bounded build/test/metadata phases; no GPU/model/remote command."""
import json
import os
import re
import sys
from pathlib import Path
from build_inputs import BASE, WORKSPACE, SCRATCH, inputs, sha
from check_process import run_owned
from check_results import require_tests
from validate_description import validate
from verify_build_inputs import verify

PRODUCT = 'darkbloom-cluster-worker'
CAPABILITY_PRODUCT = 'ProtectedCapabilityCheck'


def swift(verb, package):
    return ['swift', verb, '--package-path', str(WORKSPACE / 'libs' / package),
            '--scratch-path', str(SCRATCH), '-c', 'release', '--jobs', '2',
            '--disable-automatic-resolution', '--skip-update', '--disable-build-manifest-caching',
            '--triple', 'arm64-apple-macosx26.2', '-Xcc', '-target', '-Xcc', 'arm64-apple-macosx26.2']


def main():
    if len(sys.argv) != 3 or sys.argv[1] not in ('runtime', 'worker', 'capability', 'native') or not re.fullmatch(r'[A-Za-z0-9_-]+', sys.argv[2]):
        raise ValueError('Expected phase and one fresh relative output directory')
    phase, attempt = sys.argv[1:]
    out = BASE / attempt
    out.mkdir(mode=0o700)
    value, old, _, _, _ = inputs()
    receipt = dict(phase=phase, status='started', steps=[], sourceManifestSHA256=value['candidateManifestSHA256'],
                   sourceSnapshotSHA256=sha(BASE / 'source-snapshot-1.json'),
                   dependencySnapshotSHA256=sha(BASE / 'dependency-snapshot-1.json'),
                   modelExecuted=False, gpuExecuted=False, remoteExecuted=False,
                   protectedTransportExecuted=False, servingEnabled=False)
    print('Protected native build runner PID ' + str(os.getpid()) + ' phase ' + phase, flush=True)

    def step(argv, name, timeout):
        verify()
        result = run_owned(['/usr/bin/env', 'TMPDIR=/private/tmp/'] + argv, out, name, timeout)
        receipt['steps'].append(result)
        verify()
        return (out / (name + '.stdout')).read_bytes()

    try:
        receipt['before'] = verify()
        release = SCRATCH / 'arm64-apple-macosx/release'
        worker = WORKSPACE / 'libs/darkbloom-cluster-worker'
        fixtures = worker / 'Tests/CapabilityChecks/Fixtures'
        if phase in ('runtime', 'worker'):
            expected = json.loads((BASE / 'expected-tests.json').read_bytes())[phase]
            package = 'darkbloom-cluster' if phase == 'runtime' else 'darkbloom-cluster-worker'
            argv = ['/usr/bin/env', 'DARKBLOOM_RETAINED_PROFILE_FIXTURE=' + value['retainedFixture']['path']]
            argv += swift('test', package) + ['--filter', expected['filter']]
            stdout = step(argv, 'tests', 900)
            # XCTest results are normally stdout; retain and inspect both streams.
            receipt['testResults'] = require_tests(stdout + (out / 'tests.stderr').read_bytes(), expected)
        elif phase == 'capability':
            step(swift('build', 'darkbloom-cluster-worker') + ['--product', CAPABILITY_PRODUCT], 'build', 900)
            binary = release / CAPABILITY_PRODUCT
            golden = WORKSPACE / 'libs/darkbloom-cluster/Tests/CapabilityChecks/Fixtures/registered-qwen35-9b.capability.json'
            raw = step([str(binary), str(fixtures), str(golden)], 'input-and-producer', 15)
            actual = json.loads(raw)
            expected = json.loads((BASE / 'expected-capability.json').read_bytes())
            if actual != expected:
                raise ValueError('Original capability fixture results differ')
            raw = step(['/usr/bin/python3', '-B', str(worker / 'Tests/CapabilityChecks/check_command.py'),
                        str(binary), str(fixtures)], 'command', 115)
            result = json.loads(raw)
            if result.get('passed') is not True or result.get('actualCPUChildren') != 5:
                raise ValueError('Original capability child checks incomplete')
            receipt['capabilityResults'] = dict(inputAndProducer=actual, commands=result)
        else:
            resources = {r['path']: r for r in json.loads((old / 'runtime-bundle-1/bundle.json').read_bytes())['files']}
            metallib = old / 'runtime-bundle-1/mlx.metallib'
            if metallib.is_symlink() or sha(metallib) != resources['mlx.metallib']['sha256']:
                raise ValueError('Source-matched metallib changed')
            step(['/bin/bash', str(worker / 'build-native-worker.sh'), str(worker), str(metallib),
                  resources['mlx.metallib']['sha256']], 'build', 900)
            binary = release / PRODUCT
            if binary.is_symlink() or not binary.is_file():
                raise ValueError('Expected actual regular native worker')
            digest = sha(binary)
            args = ['--config', str(fixtures / 'registered-qwen35-9b.configuration.json'),
                    '--manifest', str(fixtures / 'registered-qwen35-9b.manifest.json'),
                    '--expected-executable-sha256', digest]
            ordinary = step([str(binary), '--describe-runtime'] + args, 'ordinary-description', 15)
            protected = step([str(binary), '--describe-protected-runtime'] + args, 'protected-description', 15)
            if any((out / (name + '.stderr')).stat().st_size for name in ('ordinary-description', 'protected-description')):
                raise ValueError('Metadata command emitted stderr')
            receipt['description'] = validate(ordinary, protected, digest, BASE / 'description-contract.json')
            if sha(binary) != digest:
                raise ValueError('Native worker changed during metadata checks')
            receipt['binary'] = dict(path=str(binary), bytes=binary.stat().st_size, sha256=digest)
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
        with (out / 'receipt.json').open('x') as stream:
            json.dump(receipt, stream, indent=2, sort_keys=True)
            stream.write('\n')
    if receipt['status'] != 'passed':
        raise ValueError('Post-build source verification failed')
    print('Protected source phase ' + phase + ' PASS; no model/GPU/remote execution', flush=True)


if __name__ == '__main__':
    os.umask(0o077)
    main()
