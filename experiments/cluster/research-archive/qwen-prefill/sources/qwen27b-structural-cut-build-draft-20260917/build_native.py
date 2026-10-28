"""One bounded native compile at a time, using the selected original closure."""
import json
import os
import sys
import time
from native_inputs import BASE, METALLIB_SHA, paths, require, sha, pin, verify_prepared, write
from owned_process import invoke_controller


def main():
    role, attempt = sys.argv[1:]
    require(attempt.isdecimal() and 1 <= int(attempt) <= 99, 'Fresh numeric build attempt required')
    spec, root, work, package, cache, binary = paths(role)
    before = verify_prepared(role)
    before.pop('actualSource'); before.pop('dependencies')
    require(json.loads((root / 'preparation.json').read_bytes())['passed'] is True, 'Preparation must pass')
    out = root / ('build-' + attempt)
    out.mkdir(mode=0o700)
    manifest_sha = sha(BASE / 'manifest.json')
    if role == 'resident':
        original_bundle = os.path.dirname(spec['bundleManifest']['path'])
        compile_argv = ['/bin/bash', str(package / 'build-native-worker.sh'), str(package),
                        original_bundle + '/mlx.metallib', METALLIB_SHA]
    else:
        compile_argv = ['/usr/bin/swift', 'build', '--package-path', str(package), '-c', 'release',
                        '--jobs', '2', '--disable-automatic-resolution', '--skip-update',
                        '--disable-build-manifest-caching', '--product', 'cluster-inference',
                        '--triple', 'arm64-apple-macosx26.2', '-Xcc', '-target', '-Xcc', 'arm64-apple-macosx26.2']
    commands = [('compile', compile_argv, 900),
                ('vtool', ['/usr/bin/xcrun', 'vtool', '-show-build', str(binary)], 10),
                ('otool', ['/usr/bin/otool', '-L', str(binary)], 10)]
    receipt = dict(role=role, passed=False, before=before, steps=[], compilerJobsMaximum=2,
                   buildSourceManifestSHA256=manifest_sha, nativeModelOrRemoteExecuted=False)
    began = time.monotonic()
    failure = None
    try:
        for name, argv, seconds in commands:
            step = dict(name=name, argv=argv, timeoutSeconds=seconds)
            receipt['steps'].append(step)
            start = time.monotonic()
            try:
                with (out / (name + '.stdout')).open('xb') as stdout, (out / (name + '.stderr')).open('xb') as stderr:
                    invoke_controller(argv, stdout, stderr, step, timeout=seconds)
            finally:
                step.update(elapsedSeconds=time.monotonic() - start,
                            stdout=pin(out / (name + '.stdout')), stderr=pin(out / (name + '.stderr')))
                write(out / (name + '.json'), step)
            require(step.get('exitCode') == 0 and step.get('reaped') and step.get('groupAbsent'), 'Build/inspection failed or group remains')
        version = (out / 'vtool.stdout').read_text()
        require(version.count('LC_BUILD_VERSION') == 1 and 'platform MACOS' in version and
                any(line.split() in (['minos', '26.2'], ['minos', '26.2.0']) for line in version.splitlines()),
                'Native minimum must remain macOS26.2')
        require(not (out / 'vtool.stderr').stat().st_size and not (out / 'otool.stderr').stat().st_size, 'Mach-O inspection stderr')
        receipt['binary'] = pin(binary)
    except BaseException as error:
        failure = error
        receipt['failure'] = type(error).__name__ + ': ' + str(error)
    finally:
        try:
            after = verify_prepared(role)
            after.pop('actualSource'); after.pop('dependencies')
            receipt['after'] = after
            require(sha(BASE / 'manifest.json') == manifest_sha, 'Build harness changed during compile')
        except BaseException as error:
            receipt['verificationFailure'] = type(error).__name__ + ': ' + str(error)
            if failure is None:
                failure = error
        receipt.update(passed=failure is None, elapsedSeconds=time.monotonic() - began)
        write(out / 'receipt.json', receipt)
    if failure is not None:
        raise failure
    print(json.dumps(dict(passed=True, role=role, seconds=receipt['elapsedSeconds'], binary=receipt['binary'])), flush=True)


if __name__ == '__main__':
    os.umask(0o077)
    main()
