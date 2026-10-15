"""One owned supervisor; its unchanged rank_worker finally retires the native PGID."""
import time
from prefill_compute_contract import Records,timeout


def supervise(rank,prompt,seconds,start,stop,memory,clock=time.monotonic,sleep=time.sleep):
    timeout(seconds);reader=Records(rank['local'],prompt);child=None;reason=error=None
    deadline=clock()+seconds;next_memory=clock()
    try:
        child=start(rank)
        while True:
            code=child.poll();reader.poll(final=code==0)
            if code is not None and code!=0:reason='native_or_supervisor_failed';break
            if clock()>=next_memory:memory();next_memory=clock()+1
            if code is not None:break
            if clock()>=deadline:reason='deadline';break
            sleep(min(.05,max(0,deadline-clock())))
    except BaseException as caught:
        reason='interrupted'if isinstance(caught,(SystemExit,KeyboardInterrupt))else'output_memory_or_startup_failure'
        error=type(caught).__name__+': '+str(caught)
    finally:
        if child is not None and child.poll()is None:
            try:stop([rank],[child])
            except BaseException as caught:reason='cleanup_failed';error=repr(caught)
        if child is not None and child.poll()is not None:child.wait(timeout=0)
    code=child.poll()if child is not None else None
    return dict(exit_code=code,supervisor_pid=child.pid if child is not None else None,
        supervisor_reaped=child is not None and code is not None,cancellation_reason=reason,error=error,
        validated_outer_records=len(reader.rows),passed=reason is None and code==0 and len(reader.rows)==2,
        independent_comparison_oracle_run=False,native_group_cleanup='unchanged rank_worker finally; independent PID inventory separate')
