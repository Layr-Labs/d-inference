"""Root-granted solo compile or metadata checks, in the separate qualified solo lineage."""
import argparse
import json
import os
import time
from build_inputs import BASE, PACKAGE, CACHE, FIXTURE, digest, verify, verify_preparation
from owned_process import invoke_controller


def main():
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument('--phase', choices=('build', 'check'), required=True)
    parser.add_argument('--attempt', type=int, choices=range(1, 10), required=True)
    args = parser.parse_args()
    out = BASE / (args.phase + '-' + str(args.attempt)); out.mkdir(mode=0o700)
    binary = CACHE / 'arm64-apple-macosx/release/cluster-inference'
    receipt = dict(schema='qwen27b_solo_build_or_check_v1', phase=args.phase, steps=[],
        compilerJobsMaximum=2, modelExecuted=False, remoteOperations=False, mainModified=False)
    failure = None
    try:
        receipt['buildPreparationManifestSHA256'] = verify_preparation()
        encoding = json.loads((BASE / ('encoding-' + str(args.attempt)) / 'receipt.json').read_bytes())
        if encoding.get('passed') is not True or encoding.get('buildPreparationManifestSHA256') != receipt['buildPreparationManifestSHA256']:
            raise ValueError('Exact successful Foundation report encoding check must precede native build')
        receipt['encodingReceiptSHA256'] = digest(BASE / ('encoding-' + str(args.attempt)) / 'receipt.json')
        receipt['before'] = verify()
        receipt['sourceSnapshotSHA256'] = digest(BASE / 'source-snapshot.json')
        receipt['dependencySnapshotSHA256'] = digest(BASE / 'dependency-source-snapshot.json')
        if args.phase == 'build':
            commands = [
                ('build', ['swift', 'build', '-c', 'release', '--jobs', '2', '--disable-automatic-resolution',
                    '--skip-update', '--disable-build-manifest-caching', '--product', 'cluster-inference',
                    '--triple', 'arm64-apple-macosx26.2', '-Xcc', '-target', '-Xcc', 'arm64-apple-macosx26.2'], 900),
                ('vtool', ['/usr/bin/xcrun', 'vtool', '-show-build', str(binary)], 10),
                ('otool', ['/usr/bin/otool', '-L', str(binary)], 10),
            ]
        else:
            built = json.loads((BASE / ('build-' + str(args.attempt)) / 'receipt.json').read_bytes())
            if built.get('passed') is not True or digest(binary) != built['binarySHA256']:
                raise ValueError('CPU check requires the corresponding successful unchanged build')
            receipt['buildReceiptSHA256'] = digest(BASE / ('build-' + str(args.attempt)) / 'receipt.json')
            commands = [('check', ['/usr/bin/env', 'DARKBLOOM_RETAINED_PROFILE_FIXTURE=' + str(FIXTURE),
                                   str(binary), '--mode', 'qwen-resident-solo-generation-check'], 60)]
        os.chdir(PACKAGE)
        for name, argv, timeout in commands:
            step = dict(name=name, argv=argv, cwd=str(PACKAGE)); receipt['steps'].append(step)
            began = time.monotonic()
            print(name + ' starting', flush=True)
            try:
                with (out / (name + '.stdout')).open('xb') as stdout, (out / (name + '.stderr')).open('xb') as stderr:
                    invoke_controller(argv, stdout, stderr, step, timeout=timeout)
            finally:
                step.update(elapsedSeconds=time.monotonic() - began,
                    stdoutSHA256=digest(out / (name + '.stdout')), stderrSHA256=digest(out / (name + '.stderr')))
                (out / 'receipt.json').write_text(json.dumps(receipt, sort_keys=True, indent=2) + '\n')
            print(name + ' terminal ' + str(step.get('exitCode')), flush=True)
            if step.get('exitCode') != 0 or not step.get('reaped') or not step.get('groupAbsent'):
                raise ValueError('Build/check/inspection failed or group remains')
        if args.phase == 'build':
            version = (out / 'vtool.stdout').read_text()
            if version.count('LC_BUILD_VERSION') != 1 or 'platform MACOS' not in version or not any(
                    line.split() in (['minos', '26.2'], ['minos', '26.2.0']) for line in version.splitlines()):
                raise ValueError('Final solo Mach-O minimum differs')
        else:
            checked = json.loads((out / 'check.stdout').read_bytes())
            if checked != dict(kind='qwen_resident_solo_generation_check', accepted=22, rejected=42,
                               modelOrKernelExecuted=False, actualRetirementProved=False):
                raise ValueError('Solo metadata check result differs')
            receipt['result'] = checked
        receipt.update(binarySHA256=digest(binary), binaryBytes=binary.stat().st_size)
    except BaseException as error:
        failure = error; receipt['failure'] = type(error).__name__ + ': ' + str(error)
    finally:
        try:
            receipt['after'] = verify()
            if verify_preparation() != receipt.get('buildPreparationManifestSHA256'):
                raise ValueError('Build preparation changed during child operation')
        except BaseException as error:
            receipt['verificationFailure'] = type(error).__name__ + ': ' + str(error)
            if failure is None: failure = error
        receipt['passed'] = failure is None
        (out / 'receipt.json').write_text(json.dumps(receipt, sort_keys=True, indent=2) + '\n')
    if failure is not None:
        raise failure
    print(json.dumps(dict(passed=True, binarySHA256=receipt['binarySHA256'])), flush=True)


if __name__ == '__main__':
    os.umask(0o077)
    main()
