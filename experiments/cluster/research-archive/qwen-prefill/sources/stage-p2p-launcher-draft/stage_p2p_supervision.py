"""One cancellation decision; injected process/clock dependencies enable CPU-only tests."""

import time

from stage_p2p_contract import RankRecords, require_timeout, validate_pair


def supervise(ranks, epoch, timeout, start, stop, clock=time.monotonic, sleep=time.sleep, scenario='success', memory_check=lambda: None):
    require_timeout(timeout)
    if len(ranks) != 2 or [rank['rank'] for rank in ranks] != [0, 1]:
        raise ValueError('Exactly two ordered local ranks are required')
    if scenario not in ('success', 'bootstrap-timeout', 'peer-loss'):
        raise ValueError('Unsupported bounded scenario')
    start_count = 1 if scenario == 'bootstrap-timeout' else 2
    readers = [RankRecords(rank['local'], rank['rank'], epoch) for rank in ranks]
    processes, reason, failure, validation = [], None, None, None
    deadline = clock() + timeout
    next_memory_check = clock()
    injected = False
    try:
        for rank in ranks[:start_count]:
            if clock() >= deadline:
                raise TimeoutError('Deadline expired while starting ranks')
            processes.append(start(rank))
        while True:
            codes = [process.poll() for process in processes]
            for index, reader in enumerate(readers[:start_count]):
                reader.poll(final=codes[index] == 0)
            if clock() >= next_memory_check:
                memory_check()
                next_memory_check = clock() + 0.25
            if scenario == 'peer-loss' and not injected and all(
                reader.records and reader.records[0]['kind'] == 'stage_p2p_ready' for reader in readers
            ) and processes[0].poll() is None:
                processes[0].terminate()
                injected = True
            if any(code is not None and code != 0 for code in codes):
                reason = 'rank_failed'
                break
            if all(code is not None for code in codes):
                if scenario != 'success':
                    reason = 'unexpected_completion'
                else:
                    validation = validate_pair(readers)
                break
            if clock() >= deadline:
                reason = 'cohort_deadline'
                break
            sleep(min(0.05, max(0, deadline - clock())))
    except BaseException as error:
        reason = ('interrupted' if isinstance(error, (KeyboardInterrupt, SystemExit)) else
                  'cohort_deadline' if isinstance(error, TimeoutError) else 'invalid_output_or_startup')
        failure = type(error).__name__ + ': ' + str(error)
    finally:
        # Always use the existing rank supervisor's cancel file + signal cleanup
        # for a live process, including a partially started cohort. The supervisor
        # finally block kills its native child group even after the leader exits.
        if any(process.poll() is None for process in processes):
            try:
                stop(ranks, processes)
            except BaseException as error:
                reason = 'cleanup_failed'
                failure = type(error).__name__ + ': ' + str(error)
        for process in processes:
            if process.poll() is not None:
                process.wait(timeout=0)
    codes = [process.poll() for process in processes]
    reaped = len(processes) == start_count and all(code is not None for code in codes)
    scenario_passed = reaped and (
        (scenario == 'success' and reason is None and codes == [0, 0] and validation is not None)
        or (scenario == 'bootstrap-timeout' and reason == 'cohort_deadline')
        or (scenario == 'peer-loss' and injected and reason == 'rank_failed'))
    return dict(scenario=scenario, scenario_passed=scenario_passed, peer_loss_injected=injected,
                configured_rank_count=2, started_rank_count=len(processes), exit_codes=codes, supervisor_pids=[p.pid for p in processes],
                supervisors_reaped=reaped,
                cancellation_reason=reason, error=failure,
                records=[reader.records for reader in readers], validation=validation,
                passed=reason is None and codes == [0, 0] and validation is not None,
                native_group_cleanup='owned rank_worker finally; no independent PID inventory in this launcher')
