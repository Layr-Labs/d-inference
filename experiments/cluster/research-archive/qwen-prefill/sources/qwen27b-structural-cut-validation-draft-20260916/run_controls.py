"""Root-granted Foundation qualification only; never starts a native model."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import sys
import time

from owned_process import invoke_controller

BASE = Path(__file__).resolve().parent


def pin(path):
    raw = path.read_bytes()
    return dict(path=str(path), bytes=len(raw), sha256=hashlib.sha256(raw).hexdigest())


def write(path, value):
    with path.open('x') as stream:
        json.dump(value, stream, indent=2, sort_keys=True)
        stream.write('\n')


def verify(frozen, inputs):
    for row in frozen['files']:
        path = BASE / row['path']
        actual = pin(path)
        if actual['bytes'] != row['bytes'] or actual['sha256'] != row['sha256']:
            raise RuntimeError('Frozen candidate changed: ' + row['path'])
    for row in inputs['files'] + inputs['dependencies']:
        if pin(Path(row['path'])) != row:
            raise RuntimeError('Exact control input changed: ' + row['path'])


def commands(out, inputs):
    dependency = inputs['dependencyDirectory']
    common = ['/usr/bin/xcrun', 'swiftc', '-j', '2', '-warnings-as-errors',
              '-target', 'arm64-apple-macos14.0', '-parse-as-library',
              '-I', dependency, '-L', dependency, '-lDarkbloomClusterProtocol',
              '-Xlinker', '-rpath', '-Xlinker', '@executable_path']
    check = out / 'check/cut-eligibility-check'
    metadata = out / 'metadata/prepare-metadata'
    owner = out / 'owner/darkbloom-owner-qualification'
    owner_command = ['/usr/bin/xcrun', 'swiftc', '-j', '2', '-swift-version', '6',
                     '-warnings-as-errors', '-target', 'arm64-apple-macos14.0',
                     '-I', dependency, '-L', dependency,
                     '-lDarkbloomClusterProtocol', '-lDarkbloomClusterProcess',
                     '-lDarkbloomClusterRemote', '-lDarkbloomClusterBootstrap',
                     '-Xlinker', '-rpath', '-Xlinker', '@executable_path']
    owner_command += [str(BASE / 'proposed/Owner' / name) for name in
                      ['OwnerNativeDiagnostics.swift', 'Qwen27BQualificationScope.swift', 'main.swift']]
    return [
        ('check-build', common + inputs['sources'] +
         [str(BASE / 'Accounting/QwenOwnedStageRequestBudget.swift'),
          str(BASE / 'Tests/CutEligibilityCheck.swift'), '-o', str(check)], 90),
        ('check', [str(check), inputs['retainedInputs']], 30),
        ('owner-build', owner_command + ['-o', str(owner)], 90),
        ('metadata-build', common + inputs['sources'] +
         [str(BASE / 'proposed/Metadata/PrepareMetadata.swift'), '-o', str(metadata)], 90),
    ]


def main():
    attempt, = sys.argv[1:]
    if not attempt.isdecimal() or not 1 <= int(attempt) <= 99:
        raise ValueError('Expected a fresh numeric attempt')
    frozen_raw = (BASE / 'manifest.json').read_bytes()
    frozen = json.loads(frozen_raw)
    inputs = json.loads((BASE / 'control-inputs.json').read_bytes())
    verify(frozen, inputs)
    out = BASE / ('controls-' + attempt)
    out.mkdir(mode=0o700)
    for role in ['check', 'owner', 'metadata']:
        directory = out / role
        directory.mkdir(mode=0o700)
        for row in inputs['dependencies']:
            source = Path(row['path'])
            if source.suffix != '.dylib' or (role != 'owner' and source.name != 'libDarkbloomClusterProtocol.dylib'):
                continue
            target = directory / source.name
            with source.open('rb') as origin, target.open('xb') as destination:
                shutil.copyfileobj(origin, destination)
            if pin(target)['sha256'] != row['sha256']:
                raise RuntimeError('Copied control dependency changed')
    result = dict(passed=False, compilerMaxJobs=2, nativeModelOrRemoteExecuted=False,
                  perStageLedgerEnabled=False, operations=[],
                  sourceManifestSHA256=hashlib.sha256(frozen_raw).hexdigest())
    began = time.monotonic()
    failure = None
    try:
        for name, argv, timeout in commands(out, inputs):
            directory = out / (name + '-evidence')
            directory.mkdir(mode=0o700)
            receipt = dict(name=name, argv=argv, timeoutSeconds=timeout)
            start = time.monotonic()
            try:
                with (directory / 'stdout').open('xb') as stdout, (directory / 'stderr').open('xb') as stderr:
                    invoke_controller(argv, stdout, stderr, receipt, timeout=timeout)
                if receipt.get('exitCode') != 0 or not receipt.get('reaped') or not receipt.get('groupAbsent'):
                    raise RuntimeError('Control operation failed or owned group remains')
                if (directory / 'stderr').stat().st_size:
                    raise RuntimeError('Control operation emitted stderr')
                receipt['passed'] = True
            finally:
                receipt.update(elapsedSeconds=time.monotonic() - start,
                               stdout=pin(directory / 'stdout'), stderr=pin(directory / 'stderr'))
                write(directory / 'receipt.json', receipt)
                result['operations'].append(receipt)
            if name == 'check':
                check = json.loads((directory / 'stdout').read_bytes())
                if (check['schema'] != 'qwen27b_structural_cut_cpu_check_v1'
                        or check['acceptedChecks'] != 69 or check['rejectedChecks'] != 29
                        or check['nativeModelExecuted'] is not False
                        or check['perStageLedgerEnabled'] is not False
                        or check['physicalQualification'] is not False):
                    raise RuntimeError('CPU result does not cover the exact staged controls')
                result['checkResult'] = pin(directory / 'stdout')
        result['outputs'] = [pin(out / name) for name in
                             ['check/cut-eligibility-check', 'owner/darkbloom-owner-qualification', 'metadata/prepare-metadata']]
    except BaseException as error:
        failure = error
        result['failure'] = type(error).__name__ + ': ' + str(error)
    finally:
        try:
            verify(frozen, inputs)
            if (BASE / 'manifest.json').read_bytes() != frozen_raw:
                raise RuntimeError('Manifest changed during qualification')
            result['inputPinsUnchanged'] = True
        except BaseException as error:
            result['verificationFailure'] = type(error).__name__ + ': ' + str(error)
            if failure is None:
                failure = error
        result.update(passed=failure is None, elapsedSeconds=time.monotonic() - began)
        write(out / 'result.json', result)
    if failure is not None:
        raise failure
    print(json.dumps(dict(passed=True, result=str(out / 'result.json'), seconds=result['elapsedSeconds'])), flush=True)


if __name__ == '__main__':
    os.umask(0o077)
    main()
