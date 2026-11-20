"""Root-granted compiler-slot entry; no native worker invocation or model mode."""
from pathlib import Path
import json
import os
import sys
import time
from build_inputs import BASE, OLD, PACKAGE, CACHE, METALLIB_SHA, sha, verify
from owned_process import invoke_controller


def main():
    attempt, = sys.argv[1:]
    if not attempt.isdecimal() or not 1 <= int(attempt) <= 99:
        raise ValueError('Expected a fresh numeric build attempt')
    out = BASE / ('native-' + attempt)
    out.mkdir(mode=0o700)
    authority = BASE / 'build-preparation-manifest.json'
    members = json.loads(authority.read_bytes())['members']
    def verify_scripts():
        for row in members:
            path = BASE / row['path']
            if path.stat().st_size != row['bytes'] or sha(path) != row['sha256']:
                raise RuntimeError('Frozen build preparation changed: ' + row['path'])
    verify_scripts()
    receipt = dict(before=verify(), steps=[], compilerJobsMaximum=2, nativeModelOrRemoteExecuted=False,
        buildPreparationManifestSHA256=sha(authority),
        sourceSnapshotSHA256=sha(BASE / 'source-snapshot-1.json'),
        dependencySnapshotSHA256=sha(BASE / 'dependency-snapshot-1.json'))
    failure = None
    try:
        commands = [
            ('build', ['/bin/bash', str(PACKAGE / 'build-native-worker.sh'), str(PACKAGE),
                       str(OLD / 'runtime-bundle-1/mlx.metallib'), METALLIB_SHA], 900),
            ('vtool', ['/usr/bin/xcrun', 'vtool', '-show-build', str(CACHE / 'arm64-apple-macosx/release/darkbloom-cluster-worker')], 10),
            ('otool', ['/usr/bin/otool', '-L', str(CACHE / 'arm64-apple-macosx/release/darkbloom-cluster-worker')], 10),
        ]
        for name, argv, timeout in commands:
            step = dict(name=name, argv=argv)
            receipt['steps'].append(step)
            started = time.monotonic()
            print(name + ' starting', flush=True)
            try:
                with (out / (name + '.stdout')).open('xb') as stdout, (out / (name + '.stderr')).open('xb') as stderr:
                    invoke_controller(argv, stdout, stderr, step, timeout=timeout)
            finally:
                step.update(elapsedSeconds=time.monotonic() - started,
                    stdoutSHA256=sha(out / (name + '.stdout')), stderrSHA256=sha(out / (name + '.stderr')))
                (out / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
            print(name + ' terminal ' + str(step.get('exitCode')), flush=True)
            if step.get('exitCode') != 0 or not step.get('reaped') or not step.get('groupAbsent'):
                raise RuntimeError('Build/inspection failed or owned group remains')
        version = (out / 'vtool.stdout').read_text()
        if version.count('LC_BUILD_VERSION') != 1 or 'platform MACOS' not in version or not any(
                line.split() in (['minos', '26.2'], ['minos', '26.2.0']) for line in version.splitlines()):
            raise RuntimeError('Final Mach-O minimum differs')
        binary = CACHE / 'arm64-apple-macosx/release/darkbloom-cluster-worker'
        receipt.update(binarySHA256=sha(binary), binaryBytes=binary.stat().st_size)
    except BaseException as error:
        failure = error
        receipt['failure'] = type(error).__name__ + ': ' + str(error)
    finally:
        try:
            receipt['after'] = verify()
            verify_scripts()
            if sha(authority) != receipt['buildPreparationManifestSHA256']:
                raise RuntimeError('Build preparation manifest changed during build')
        except BaseException as error:
            receipt['verificationFailure'] = type(error).__name__ + ': ' + str(error)
            if failure is None:
                failure = error
        receipt['passed'] = failure is None
        (out / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
    if failure is not None:
        raise failure
    print(json.dumps(dict(passed=True, binarySHA256=receipt['binarySHA256'])), flush=True)


if __name__ == '__main__':
    os.umask(0o077)
    main()
