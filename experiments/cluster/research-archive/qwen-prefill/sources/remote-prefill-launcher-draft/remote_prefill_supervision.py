"""Own one local SSH client while the unchanged remote worker owns native PGID."""
import time
from prefill_compute_contract import Records, timeout


def supervise(rank, prompt, seconds, start, stop, memory, clock=time.monotonic, sleep=time.sleep):
    timeout(seconds)
    reader, child, reason, error = Records(rank['local'], prompt), None, None, None
    deadline, next_memory = clock() + seconds, clock()
    try:
        child = start(rank)
        while True:
            code = child.poll()
            reader.poll(final=code == 0)
            if code is not None and code != 0:
                reason = 'native_remote_supervisor_or_ssh_failed'
                break
            remaining = deadline - clock()
            if remaining <= 0:
                reason = 'local_parent_deadline'
                break
            if clock() >= next_memory:
                memory(min(3, remaining))
                next_memory = clock() + 1
            if code is not None:
                break
            sleep(min(.05, max(0, deadline - clock())))
    except BaseException as caught:
        reason = 'interrupted' if isinstance(caught, (SystemExit, KeyboardInterrupt)) else 'output_memory_or_ssh_failure'
        error = type(caught).__name__ + ': ' + str(caught)
    finally:
        # An exited SSH client is not proof that its remote descendants died.
        # Failures still touch the owned remote cancel file through stop().
        if child is not None and (reason is not None or child.poll() is None):
            try:
                stop([rank], [child])
            except BaseException as caught:
                reason, error = 'cleanup_failed', repr(caught)
        if child is not None and child.poll() is not None:
            child.wait(timeout=0)
    code = child.poll() if child is not None else None
    return dict(exit_code=code, local_ssh_client_pid=child.pid if child is not None else None,
                local_ssh_client_reaped=child is not None and code is not None,
                remote_process_reaping_independently_verified=False,
                cancellation_reason=reason, error=error, validated_outer_records=len(reader.rows),
                passed=reason is None and code == 0 and len(reader.rows) == 2,
                independent_comparison_oracle_run=False,
                remote_cleanup_contract='unchanged rank_worker finally owns native PGID; cancel file and native alarm are independent bounds')
