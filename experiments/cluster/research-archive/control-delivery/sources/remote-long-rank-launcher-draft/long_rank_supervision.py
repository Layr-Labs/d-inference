"""One deadline/fence for both SSH clients; preserve primary and cleanup errors."""
import time
from long_rank_records import Records, peers, timeout, require


def supervise(ranks, inputs, epoch, scheduling, seconds, start, stop, memory, clock=time.monotonic, sleep=time.sleep):
    timeout(seconds); require([rank['rank'] for rank in ranks] == [0, 1], 'Two ordered ranks required')
    readers = [Records(rank['local'], rank['rank'], epoch, scheduling, inputs) for rank in ranks]
    children, reason, error, cleanup_errors = [], None, None, []
    deadline, next_memory = clock() + seconds, clock()
    try:
        for rank in ranks:
            children.append(start(rank))
        while True:
            codes = [child.poll() for child in children]
            for code, reader in zip(codes, readers):
                reader.poll(final=code == 0)
            peers(readers)
            if any(code is not None and code != 0 for code in codes):
                reason = 'native_remote_supervisor_or_ssh_failed'; break
            remaining = deadline - clock()
            if remaining <= 0:
                reason = 'local_parent_deadline'; break
            if clock() >= next_memory:
                memory(min(3, remaining)); next_memory = clock() + 1
            if all(code is not None for code in codes):
                break
            sleep(min(.05, max(0, deadline - clock())))
    except BaseException as caught:
        reason = 'interrupted' if isinstance(caught, (SystemExit, KeyboardInterrupt)) else 'output_memory_or_ssh_failure'
        error = type(caught).__name__ + ': ' + str(caught)
    finally:
        if children and (reason is not None or any(child.poll() is None for child in children)):
            try:
                # Touch both owned remote cancellation paths even if one local
                # SSH client has already exited or the second start failed.
                stop(ranks, children)
            except BaseException as caught:
                cleanup_errors.append(dict(phase='cohort_stop', error=type(caught).__name__ + ': ' + str(caught)))
        for index, child in enumerate(children):
            if child.poll() is not None:
                try:
                    child.wait(timeout=0)
                except BaseException as caught:
                    cleanup_errors.append(dict(phase='ssh_wait', rank=index, error=repr(caught)))
    codes = [child.poll() for child in children]
    complete = len(children) == 2 and codes == [0, 0] and all(len(reader.rows) == 2 for reader in readers)
    return dict(exit_codes=codes + [None] * (2 - len(codes)),
        local_ssh_client_pids=[child.pid for child in children],
        local_ssh_clients_reaped=[child.poll() is not None for child in children],
        remote_process_reaping_independently_verified=False,
        cancellation_reason=reason, error=error, cleanup_errors=cleanup_errors,
        passed=complete and reason is None and not cleanup_errors,
        validation=dict(records_per_rank=[len(reader.rows) for reader in readers],
                        shared_agreement_matches=all(reader.rows for reader in readers) and reason is None,
                        nested_execution_oracle_run=False),
        remote_cleanup_contract='both unchanged rank_worker finally blocks own native PGIDs; cancel files and native alarms bound failure')
