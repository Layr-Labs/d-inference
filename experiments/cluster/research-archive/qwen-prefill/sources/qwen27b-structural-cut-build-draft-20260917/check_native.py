"""Explicit model-free modes only; no socket connect or native forward path."""
import json
import os
from pathlib import Path
import sys
import time
from native_inputs import BASE, paths, checked, require, sha, pin, verify_prepared, write
from owned_process import invoke_controller


def main():
    role, attempt = sys.argv[1:]
    require(attempt.isdecimal() and 1 <= int(attempt) <= 99, 'Fresh numeric check attempt required')
    spec, root, work, package, cache, binary = paths(role)
    before = verify_prepared(role)
    before.pop('actualSource'); before.pop('dependencies')
    build = json.loads((root / ('build-' + attempt) / 'receipt.json').read_bytes())
    require(build['passed'] is True and build['binary'] == pin(binary), 'Exact successful binary build required')
    extra = json.loads((BASE / 'extra-inputs.json').read_bytes())
    checked(extra['referenceRetainedFixture'])
    out = root / ('check-' + attempt)
    out.mkdir(mode=0o700)
    receipt = dict(role=role, passed=False, before=before, steps=[], nativeModelOrRemoteExecuted=False,
                   binary=pin(binary), buildSourceManifestSHA256=sha(BASE / 'manifest.json'))
    began = time.monotonic()
    failure = None

    def execute(name, argv, seconds, expected=0):
        step = dict(name=name, argv=argv, timeoutSeconds=seconds, expectedExitCode=expected)
        receipt['steps'].append(step)
        started = time.monotonic()
        try:
            with (out / (name + '.stdout')).open('xb') as stdout, (out / (name + '.stderr')).open('xb') as stderr:
                invoke_controller(argv, stdout, stderr, step, timeout=seconds)
        finally:
            step.update(elapsedSeconds=time.monotonic() - started,
                        stdout=pin(out / (name + '.stdout')), stderr=pin(out / (name + '.stderr')))
            write(out / (name + '.json'), step)
        require(step.get('exitCode') == expected and step.get('reaped') and step.get('groupAbsent'), 'Pure argument/check failed or group remains')
        if expected == 0:
            require(not (out / (name + '.stderr')).stat().st_size, 'Successful pure check emitted stderr')
        else:
            error = (out / (name + '.stderr')).read_bytes()
            require(not (out / (name + '.stdout')).stat().st_size and 0 < len(error) <= 4096 and
                    error.startswith(b'darkbloom-cluster-worker: '), 'Negative native check failure framing')
        return (out / (name + '.stdout')).read_bytes()

    try:
        if role == 'reference':
            argv = ['/usr/bin/env', 'DARKBLOOM_RETAINED_PROFILE_FIXTURE=' + extra['referenceRetainedFixture']['path'],
                    str(binary), '--mode', 'qwen-registered-full-generation-reference-check']
            value = json.loads(execute('reference-metadata', argv, 60))
            require(value == dict(accepted=53, rejected=86, actualAllocatorOrLiveResourceAdmissionPerformed=False,
                                 cpuOnly=True, kind='qwen_full_generation_reference_entry_check', modelOrNativeForwardExecuted=False),
                    'Reference exact old checks plus ten structural-cut positives differ')
            receipt['result'] = value
        else:
            clock = execute('clock', [str(binary), 'clock'], 5)
            require(clock.strip().isdigit() and len(clock) <= 32, 'Native local clock format')
            # Every invocation resamples the actual executable clock, keeping
            # the local <=300s check independent of Python clock conversion.
            for cut in list(range(4, 61, 4)) + [0, 3, 21, 63, 64]:
                local = int(execute('clock-' + str(cut), [str(binary), 'clock'], 5).strip())
                deadline = local + 30_000_000_000
                fields = ['--model-dir', '/nonexistent/registered-cut-argument-only-model', '--rank', '0',
                          '--stage-cut', str(cut), '--membership-epoch', '11111111-1111-4111-8111-111111111111',
                          '--model-id', 'registered_qwen38_27b',
                          '--artifact-sha256', 'bbd0e0adcfe74e095073fefd0b9e116e4311d606ad9989cf81f8175e8ac18463',
                          '--configuration-sha256', '4691da94a1b4ef415aad112ec46abebd33f8a41ad07380e486c0526eb945c1ff',
                          '--peer0-id', 'darkbloom-24', '--peer0-build-sha256', receipt['binary']['sha256'],
                          '--peer1-id', 'darkbloom-48', '--peer1-build-sha256', receipt['binary']['sha256'],
                          '--deadline-uptime-nanoseconds', str(deadline),
                          '--bootstrap-socket-path', '/nonexistent/cut-check.sock', '--bootstrap-owner-pid', str(os.getpid()),
                          '--bootstrap-deadline-uptime-nanoseconds', str(deadline)]
                execute('cut-' + str(cut), [str(binary), 'check-arguments'] + fields, 5,
                        expected=0 if cut in range(4, 61, 4) else 1)
            # This executable is explicitly 27B-only. A syntactically valid
            # structural cut cannot switch its registered model identity.
            other = list(fields)
            other[other.index('--stage-cut') + 1] = '20'
            other[other.index('--model-id') + 1] = 'registered_qwen35_9b'
            other[other.index('--artifact-sha256') + 1] = '127de76b4ef82b7aaa0acaac0ee31c784cff066eda64291f521f051469b7c24b'
            other[other.index('--configuration-sha256') + 1] = 'c8e767de4953e58352fbc1acbf6615329075ed02fe16a36b8065714d85ee4423'
            execute('foreign-model', [str(binary), 'check-arguments'] + other, 5, expected=1)
            receipt['result'] = dict(acceptedCuts=list(range(4, 61, 4)), rejectedCuts=[0, 3, 21, 63, 64],
                                    foreignModelRefused=True, modelPathRead=False, bootstrapConnected=False)
    except BaseException as error:
        failure = error
        receipt['failure'] = type(error).__name__ + ': ' + str(error)
    finally:
        try:
            after = verify_prepared(role)
            after.pop('actualSource'); after.pop('dependencies')
            receipt['after'] = after
            require(pin(binary) == receipt['binary'] and sha(BASE / 'manifest.json') == receipt['buildSourceManifestSHA256'], 'Check source/binary changed')
        except BaseException as error:
            receipt['verificationFailure'] = type(error).__name__ + ': ' + str(error)
            if failure is None:
                failure = error
        receipt.update(passed=failure is None, elapsedSeconds=time.monotonic() - began)
        write(out / 'receipt.json', receipt)
    if failure is not None:
        raise failure
    print(json.dumps(dict(passed=True, role=role, result=receipt['result'], seconds=receipt['elapsedSeconds'])), flush=True)


if __name__ == '__main__':
    os.umask(0o077)
    main()
