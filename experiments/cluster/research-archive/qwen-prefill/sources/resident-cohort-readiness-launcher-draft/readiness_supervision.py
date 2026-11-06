"""Expected negative scenarios are distinct from native success and cleanup."""
import time
from readiness_config import parent_seconds, require
from readiness_contract import validate_record, validate_pair
from readiness_stream import Streams


def supervise(ranks, epoch, scenario, start, stop, memory=lambda deadline: None,
              started=lambda rank, process: None, clock=time.monotonic, sleep=time.sleep):
    require(len(ranks) == 2 and [r['rank'] for r in ranks] == [0, 1] and
            all(r['host'] is None for r in ranks), 'Two ordered local rank configurations required')
    timeout = parent_seconds(scenario)
    count = 1 if scenario == 'missing-peer' else 2
    streams = [Streams(r['local'], r['rank'], epoch, scenario, validate_record) for r in ranks]
    children, cleanup = [], []
    reason = error = validation = None
    codes_before_cancellation = None
    deadline = clock() + timeout
    next_memory = clock()
    try:
        for rank in ranks[:count]:
            if clock() >= deadline:
                raise TimeoutError('Readiness startup deadline expired')
            child = start(rank); children.append(child)
            started(rank, child)
        while True:
            for stream in streams[:count]:
                stream.poll()
            observed_codes = [child.poll() for child in children]
            if any(code is not None and code != 0 for code in observed_codes):
                if scenario == 'warmup-mismatch' and observed_codes == [None, 1]:
                    if clock() >= deadline:
                        raise TimeoutError('Readiness mismatch observed after parent deadline')
                    streams[1].negative(mismatch=True); streams[0].negative()
                    if clock() >= deadline:
                        raise TimeoutError('Readiness mismatch validation exceeded parent deadline')
                    reason = 'expected_warmup_mismatch'
                else:
                    reason = 'unexpected_rank_failure'
                break
            if scenario != 'match' and any(code == 0 for code in observed_codes):
                raise ValueError('Negative scenario completed before parent cancellation')
            if clock() >= next_memory:
                memory(deadline); next_memory = clock() + .25
            # Observation time is charged before success or expected-negative admission.
            if clock() >= deadline:
                raise TimeoutError('Readiness parent execution deadline expired')
            codes = [child.poll() for child in children]
            if scenario == 'warmup-mismatch' and codes[1] == 1 and codes[0] is None:
                streams[1].negative(mismatch=True); streams[0].negative()
                if clock() >= deadline:
                    raise TimeoutError('Readiness mismatch validation exceeded parent deadline')
                reason = 'expected_warmup_mismatch'
                break
            if any(code is not None and code != 0 for code in codes):
                reason = 'unexpected_rank_failure'
                break
            if all(code is not None for code in codes):
                require(scenario == 'match', 'Negative scenario completed unexpectedly')
                for stream in streams:
                    stream.success()
                validation = validate_pair(streams)
                if clock() >= deadline:
                    raise TimeoutError('Readiness success validation exceeded parent deadline')
                break
            sleep(min(.05, max(0, deadline - clock())))
    except BaseException as caught:
        reason = ('parent_deadline' if isinstance(caught, TimeoutError) else 'interrupted'
                  if isinstance(caught, (KeyboardInterrupt, SystemExit)) else 'output_memory_or_startup_failure')
        error = type(caught).__name__ + ': ' + str(caught)
    finally:
        if reason is not None or validation is None:
            # An observed exit before cancellation is not evidence of parent retirement.
            codes_before_cancellation = [child.poll() for child in children]
            try:
                stop(ranks, children)
            except BaseException as caught:
                cleanup.append(dict(operation='stop_owned_cohort', error=repr(caught)))
        for child in children:
            try:
                if child.poll() is None:
                    raise RuntimeError('Owned supervisor is still running')
                child.wait(timeout=0)
            except BaseException as caught:
                cleanup.append(dict(operation='reap_supervisor', pid=child.pid, error=repr(caught)))
    codes = [child.poll() for child in children]
    reaped = len(children) == count and all(code is not None for code in codes) and not cleanup
    native_success = scenario == 'match' and reason is None and codes == [0, 0] and validation is not None
    passed = reaped and native_success
    try:
        if scenario == 'warmup-mismatch' and reason == 'expected_warmup_mismatch' and reaped:
            streams[0].negative(); streams[1].negative(mismatch=True)
            passed = True
        if (scenario == 'missing-peer' and reason == 'parent_deadline' and reaped and
                codes_before_cancellation == [None]):
            streams[0].negative()
            require(codes[0] != 0, 'Missing peer produced native success')
            passed = True
    except BaseException as caught:
        cleanup.append(dict(operation='final_negative_stream_validation', error=repr(caught)))
        passed = False
    return dict(scenario=scenario, scenario_passed=passed, native_success=native_success,
        configured_rank_count=2, started_rank_count=len(children),
        execution_timeout_seconds=timeout, supervisor_pids=[x.pid for x in children],
        supervisor_exit_codes=codes, supervisors_reaped=reaped,
        supervisor_exit_codes_before_cancellation=codes_before_cancellation,
        missing_peer_running_observed_before_parent_cancellation=(
            scenario == 'missing-peer' and reason == 'parent_deadline' and
            codes_before_cancellation == [None]),
        primary_reason=reason, primary_error=error, cleanup_errors=cleanup,
        records=[stream.record for stream in streams], validation=validation,
        native_waitpid_owned_by_unchanged_rank_worker=True, independent_native_waitpid=False,
        missing_peer_tests_startup_cancellation_only=scenario == 'missing-peer')
