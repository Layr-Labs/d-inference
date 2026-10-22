#!/usr/bin/env python3
"""Private one-request reference owner; never imported by product inference."""
import argparse
import hashlib
import os
from pathlib import Path
import signal
import sys
import time

sys.dont_write_bytecode = True
from binding_common import canonical, parse, require
from solo_contract import admitted, expected_identity, report
from solo_progress import loaded, retired, reconcile
from solo_inputs import (Pins, native_spec, path, validate_job, verify_inputs,
                              verify_launcher, write_json, write_new)
from reference_resources import ResourceGate
from worker_processes import PipeWorkers, cleanup_error_text


def serve(job, spec, tokens, expected_tokens, run, gate, pins, timeout=315):
    """Actual Popen ownership. Tests inject a fabricated command at this seam.

    Only main() may construct the real command after pinned deployment checks.
    This function does not turn arbitrary WorkerSpec input into qualification.
    """
    started = time.monotonic()
    run = Path(run)
    expected = expected_identity(job, tokens, expected_tokens)
    result = dict(schema='private_resident_solo_generation_terminal_v2', status='starting',
        jobSHA256=hashlib.sha256(canonical(job)+b'\n').hexdigest(), requestID=job['request_id'],
        sourceManifestSHA256=job['source_manifest_sha256'], bundleSHA256=job['bundle_sha256'],
        nativeSHA256=job['native_sha256'], metallibSHA256=job['metallib_sha256'],
        primaryFailure=None, postflightErrors=[], recordsAccepted=0, sourceInputsUnchanged=False,
        nativeLeaderReaped=False, ownedGroupFenceComplete=False, outputComplete=False,
        independentNumericalComparisonPerformed=False, independentPlanDerivationPerformed=False,
        modelPayloadVerifiedByPython=False, sourceToBinaryBuildIndependentlyVerified=False,
        loadedMetallibIndependentlyVerified=False, physicalTransferQualified=False,
        throughputMeasurementValid=False, descendantReapingIndependentlyProven=False,
        lastAcceptedPhase='starting', completedRequestRecords=0, cohortTimingEligible=False)
    pipes = None
    primary = None
    handlers = {}

    def guard(phase):
        require(time.monotonic()-started < timeout, 'Reference parent lifetime expired')
        gate(phase)
        require(time.monotonic()-started < timeout, 'Reference resource observation exceeded lifetime')

    def interrupted(number, _):
        raise SystemExit(128+number)

    def secondary(operation, error):
        nonlocal primary
        result['postflightErrors'].append(dict(operation=operation, error=cleanup_error_text(error)[0]))
        if not isinstance(error, Exception) and isinstance(primary, (Exception, type(None))):
            primary = error

    try:
        for number in (signal.SIGHUP, signal.SIGTERM, signal.SIGINT):
            handlers[number] = signal.getsignal(number)
            signal.signal(number, interrupted)
        guard('prelaunch')
        pipes = PipeWorkers((spec,), run/'native', timeout, guard)
        pipes.start()
        child = pipes.children[0]
        owner = dict(nativePID=child.pid, nativePGID=child.pid, supervisorPID=os.getpid(),
            nativeArgv=list(spec.argv), nativeEnvironment=dict(spec.env),
            nativeSeconds=300, parentSeconds=timeout)
        write_json(run/'owner.json', owner)
        result['owner'] = owner
        first = pipes.collect('native-admitted', lambda _, raw: admitted(raw, expected))[0]
        result['recordsAccepted'] = 1; result['lastAcceptedPhase'] = 'admitted'
        model = pipes.collect('native-loaded', lambda _, raw: loaded(raw, expected, first))[0]
        result['recordsAccepted'] = 2; result['lastAcceptedPhase'] = 'model-loaded'
        progress = []; previous = model['publishedNanoseconds']
        for index in range(1 + job['measured_count']):
            row = pipes.collect('native-request-' + str(index), lambda _, raw: retired(
                raw, expected, first, index, previous))[0]
            progress.append(row); previous = row['publishedNanoseconds']
            result['recordsAccepted'] += 1
            result['completedRequestRecords'] = len(progress)
            result['lastAcceptedPhase'] = 'request-' + str(index) + '-retired'
        final = pipes.collect('native-report', lambda _, raw: report(raw, expected, first,
            child.pid, path(job['deployment'])))[0]
        reconcile(final, model, progress)
        result['recordsAccepted'] += 1; result['lastAcceptedPhase'] = 'complete-report'
        # The original bytes live exclusively in native/worker-0.stdout.
        result['requestFingerprint'] = expected['requestFingerprint']
        result['reportedPlanSHA256'] = first['referencePlanSHA256']
        result['selectedTokenIDsSHA256'] = final['requests'][0]['execution']['selectedTokenIDsSHA256']
        result['requests'] = [row['execution']['timing'] for row in final['requests']]
        result['warmupCount'] = 1; result['measuredCount'] = job['measured_count']
        pipes.finish()
        guard('completed-native')
        result['status'] = 'completed'
    except BaseException as error:
        primary = error
        result['status'] = 'failed'
        result['primaryFailure'] = cleanup_error_text(error)[0]
    finally:
        if pipes is not None:
            try:
                pipes.close(kill=result['status'] != 'completed')
            except BaseException as error:
                secondary('native_cleanup', error)
            result['nativeLeaderReaped'] = bool(pipes.children) and all(p.returncode is not None for p in pipes.children)
            result['ownedGroupFenceComplete'] = bool(pipes.children) and all(p.pid in pipes._fenced_groups for p in pipes.children)
            result['nativeExitCodes'] = [p.returncode for p in pipes.children]
            result['outputComplete'] = pipes.complete_output
            result['cleanupErrors'] = list(pipes.cleanup_errors)
            try:
                result['streams'] = pipes.retained_streams()
            except BaseException as error:
                secondary('retained_stream_hashes', error)
        for name, callback in [('source_input_recheck', pins.recheck), ('resource_postflight', lambda: gate('postflight'))]:
            try:
                callback()
                if name == 'source_input_recheck':
                    result['sourceInputsUnchanged'] = True
            except BaseException as error:
                secondary(name, error)
        if time.monotonic()-started >= timeout:
            result['postflightErrors'].append(dict(operation='absolute_deadline', error='Parent lifetime exhausted'))
        if (result['postflightErrors'] or result.get('cleanupErrors') or not result['nativeLeaderReaped']
                or not result['ownedGroupFenceComplete']):
            result['status'] = 'failed'
        result['cohortTimingEligible'] = result['status'] == 'completed'
        result['elapsedSeconds'] = time.monotonic()-started
        try:
            write_json(run/'terminal.json', result)
        finally:
            for number, previous in handlers.items():
                signal.signal(number, previous)
    if primary is not None and not isinstance(primary, Exception):
        raise primary
    return 0 if result['status'] == 'completed' else 1


def main(arguments=None):
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument('--job', required=True)
    parser.add_argument('--job-sha256', required=True)
    parser.add_argument('--launcher-sha256', required=True)
    args = parser.parse_args(arguments)
    pins = Pins()
    verify_launcher(Path(__file__).resolve().parent, args.launcher_sha256, pins)
    raw = pins.read(path(args.job), 16384, args.job_sha256)['raw']
    job = validate_job(parse(raw))
    require(raw == canonical(job)+b'\n', 'Job must be canonical JSON with final LF')
    run = path(job['run_dir'])
    require(run.parent.resolve() == run.parent, 'Run parent contains a symlink')
    run.mkdir(mode=0o700)
    write_new(run/'job.json', raw)
    log = os.fdopen(os.open(run/'resources.jsonl', os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), 'wb', buffering=0)
    entered = False
    try:
        gate = ResourceGate(lambda row: PipeWorkers._write_all(log, canonical(row)+b'\n'))
        gate('prelaunch')
        prompt, tokens, expected_raw, expected_tokens = verify_inputs(job, pins)
        write_new(run/'prompt.json', prompt)
        write_new(run/'expected.json', expected_raw)
        pins.read(run/'expected.json', 16384, job['expected_sha256'])
        pins.read(run/'prompt.json', 65536, job['prompt_sha256'])
        pins.recheck()
        gate('prelaunch')
        spec = native_spec(job)
        entered = True
        return serve(job, spec, tokens, expected_tokens, run, gate, pins)
    except BaseException as error:
        if not entered:
            write_json(run/'terminal.json', dict(schema='private_resident_solo_generation_terminal_v1',
                status='failed', nativeNotStarted=True, primaryFailure=cleanup_error_text(error)[0],
                nativeLeaderReaped=False, ownedGroupFenceComplete=False,
                independentNumericalComparisonPerformed=False, throughputMeasurementValid=False))
        raise
    finally:
        log.close()


if __name__ == '__main__':
    raise SystemExit(main())
