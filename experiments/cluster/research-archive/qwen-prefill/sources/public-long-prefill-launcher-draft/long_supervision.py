"""One fresh local owner or two local stage owners, with one failure decision."""
import time
from .common import integer, require
from .long_profile import MAX_PARENT_TIMEOUT
from .long_rank_contract import peers
from .long_stream import Records


def run(ranks, context, timeout, start, stop, memory, clock=time.monotonic, sleep=time.sleep):
    integer(timeout, 1, MAX_PARENT_TIMEOUT)
    expected = [0, 1] if context['mode'] == 'long-prefill-ranks' else [0]
    require([rank['rank'] for rank in ranks] == expected and all(rank['host'] is None for rank in ranks),
            'Long checks require exactly their local owners')
    readers = [Records(rank['local'], rank['rank'], context) for rank in ranks]
    children, cleanup = [], []; reason = error = validation = None
    deadline = clock() + timeout; next_memory = clock()
    try:
        for rank in ranks:
            if clock() >= deadline: raise TimeoutError('Long startup deadline expired')
            children.append(start(rank))
        while True:
            codes = [child.poll() for child in children]
            for reader, code in zip(readers, codes): reader.poll(final=code == 0)
            if len(readers) == 2: peers(readers)
            if any(code is not None and code != 0 for code in codes): reason = 'rank_failed'; break
            if clock() >= next_memory: memory(); next_memory = clock() + 1
            if clock() >= deadline: raise TimeoutError('Long cohort deadline expired')
            if all(code is not None for code in codes):
                validation = dict(records_per_owner=[len(reader.rows) for reader in readers],
                    outer_identity_and_completion_validated=True, peer_agreement_validated=len(readers) == 2,
                    numerical_action_wire_timing_audit_performed=False)
                break
            sleep(min(.05, max(0, deadline - clock())))
    except BaseException as caught:
        reason = ('cohort_deadline' if isinstance(caught, TimeoutError) else 'interrupted'
                  if isinstance(caught, (KeyboardInterrupt, SystemExit)) else 'output_memory_or_startup_failure')
        error = type(caught).__name__ + ': ' + str(caught)
    finally:
        if reason is not None or validation is None:
            try: stop(ranks, children)
            except BaseException as caught: cleanup.append(dict(operation='stop_owned_cohort', error=repr(caught)))
        for child in children:
            try:
                if child.poll() is not None: child.wait(timeout=0)
                else: cleanup.append(dict(operation='reap_supervisor', pid=child.pid, error='supervisor still running'))
            except BaseException as caught: cleanup.append(dict(operation='reap_supervisor', pid=child.pid, error=repr(caught)))
    codes = [child.poll() for child in children]
    return dict(exit_codes=codes, supervisor_pids=[child.pid for child in children],
        supervisors_reaped=len(children) == len(ranks) and all(code is not None for code in codes) and not cleanup,
        cancellation_reason=reason, error=error, cleanup_errors=cleanup, validation=validation,
        passed=reason is None and not cleanup and codes == [0] * len(ranks) and validation is not None,
        native_cleanup='unchanged rank_worker finally; independent native PID inventory not performed')
