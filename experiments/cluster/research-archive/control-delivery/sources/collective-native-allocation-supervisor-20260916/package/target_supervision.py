"""One actual native process, preserved failure, and separate cleanup observations."""
import os
import signal
import time

from binding_common import require
from target_contract import JOBS, validate_result
from target_inputs import write_json
from worker_processes import PipeWorkers, cleanup_error_text


def owned_groups_absent(children):
    rows = []
    for child in children:
        try:
            os.killpg(child.pid, 0)  # Observation only; never signal a discovered PID.
            absent = False
        except ProcessLookupError:
            absent = True
        rows.append(dict(ownedPID=child.pid, ownedPGID=child.pid, absent=absent))
    return rows


def serve(spec, run, started, gate, pins, postflight, fixture, host):
    deadline = started + 90
    job = JOBS[fixture]
    result = dict(schema='collective_allocation_native_observation_v1', fixture=fixture, status='starting',
        primaryFailure=None, postflightErrors=[], cleanupErrors=[], nativeResult=None,
        nativeLeaderReaped=False, ownedGroupsAbsent=False, outputComplete=False,
        sourceInputsUnchanged=False, journalEmptyAfterExit=False, processInventoryClear=False,
        fabricatedTargetWeights=False, modelTrunkExecutionObserved=False, registeredCheckpointExecution=False, bilateralVerification=False,
        windowStateExecutionObserved=False, sharedTargetTransactionObserved=False,
        nativeAllocationExecutionObserved=False, rdmaExecutionObserved=False, protectedServingEnabled=False,
        registeredProfileExecution=False, throughputMeasurementValid=False,
        protocolOwnerLeaseReleaseObserved=False, journalMutationPerformed=False)
    pipes, primary = None, None
    previous = {}

    def guard(phase):
        require(time.monotonic() < deadline, 'Parent operation deadline expired')
        gate(phase)
        require(time.monotonic() < deadline, 'Resource observation exhausted parent deadline')

    def interrupted(number, _):
        raise SystemExit(128+number)

    def secondary(operation, error):
        nonlocal primary
        result['postflightErrors'].append(dict(operation=operation, error=cleanup_error_text(error)[0]))
        if primary is None or not isinstance(error, Exception):
            primary = error

    try:
        for number in (signal.SIGHUP, signal.SIGTERM, signal.SIGINT):
            previous[number] = signal.getsignal(number)
            signal.signal(number, interrupted)
        guard('prelaunch')
        seconds = int(deadline-time.monotonic())
        require(seconds >= job['processAlarmSeconds'] + 1, 'Insufficient original parent lifetime for native alarm and cleanup')
        pipes = PipeWorkers((spec,), run/'native', seconds, guard)
        pipes.start()
        write_json(run/'owner.json', dict(nativePIDs=[p.pid for p in pipes.children],
            nativePGIDs=[p.pid for p in pipes.children], supervisorPID=os.getpid(),
            nativeArgv=list(spec.argv), nativeEnvironment=dict(spec.env), nativeAlarmSeconds=job['processAlarmSeconds'],
            parentDeadlineMonotonic=deadline, remainingGroupWatchdogSeconds=seconds))
        result['nativeResult'] = pipes.collect('native-state', lambda _, raw: validate_result(raw, fixture, host))[0]
        result['nativeAllocationExecutionObserved'] = True
        result['windowStateExecutionObserved'] = False
        result['sharedTargetTransactionObserved'] = False
        pipes.finish()
        guard('native-completed')
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
                secondary('owned_native_cleanup', error)
            result.update(nativePIDs=[p.pid for p in pipes.children],
                nativeExitCodes=[p.returncode for p in pipes.children],
                nativeLeaderReaped=bool(pipes.children) and all(p.returncode is not None for p in pipes.children),
                outputComplete=pipes.complete_output, cleanupErrors=list(pipes.cleanup_errors),
                watchdogExpired=pipes.expired.is_set())
            for operation, callback in [('owned_group_observation', lambda: owned_groups_absent(pipes.children)),
                                         ('retained_streams', pipes.retained_streams)]:
                try:
                    observation = callback()
                    result[operation] = observation
                    if operation == 'owned_group_observation':
                        result['ownedGroupsAbsent'] = bool(observation) and all(x['absent'] for x in observation)
                except BaseException as error:
                    secondary(operation, error)
        for name, callback in [('source_input_recheck', pins.recheck),
                               ('resource_postflight', lambda: gate('postflight')),
                               ('journal_and_process_postflight', postflight)]:
            try:
                observation = callback()
                if name == 'source_input_recheck': result['sourceInputsUnchanged'] = True
                if name == 'journal_and_process_postflight':
                    result['journalEmptyAfterExit'] = result['processInventoryClear'] = True
                    result['postflight'] = observation
            except BaseException as error:
                secondary(name, error)
        if time.monotonic() >= deadline:
            result['postflightErrors'].append(dict(operation='parent_deadline', error='Original 90s budget exhausted'))
        if (result['postflightErrors'] or result['cleanupErrors'] or not result['nativeLeaderReaped']
                or not result['ownedGroupsAbsent'] or not result['outputComplete']
                or result.get('nativeExitCodes') != [0] or not result['sourceInputsUnchanged']
                or not result['journalEmptyAfterExit'] or not result['processInventoryClear']):
            result['status'] = 'failed'
        result['elapsedSeconds'] = time.monotonic()-started
        try:
            write_json(run/'terminal.json', result)
        finally:
            for number, handler in previous.items(): signal.signal(number, handler)
    if primary is not None and not isinstance(primary, Exception): raise primary
    return 0 if result['status'] == 'completed' else 1
