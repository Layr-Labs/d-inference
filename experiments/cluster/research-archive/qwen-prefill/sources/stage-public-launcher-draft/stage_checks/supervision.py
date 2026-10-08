"""Single fresh cohort; existing runtime supervisors own each native child group."""
import time
from .stream import Records
from .common import integer,require


def run(ranks,epoch,context,namespace,timeout,start,stop,memory,clock=time.monotonic,sleep=time.sleep):
    integer(timeout,1,60 if context['mode']=='p2p' else 180)
    require([rank['rank'] for rank in ranks]==[0,1],'Exactly two ordered ranks required')
    readers=[Records(rank['local'],rank['rank'],epoch,context,namespace) for rank in ranks]
    children=[];reason=error=validation=None;deadline=clock()+timeout;next_memory=clock()
    try:
        for rank in ranks:
            if clock()>=deadline:raise TimeoutError('Startup deadline expired')
            children.append(start(rank))
        while True:
            codes=[child.poll() for child in children]
            for i,reader in enumerate(readers):reader.poll(final=codes[i]==0)
            if any(code is not None and code!=0 for code in codes):reason='rank_failed';break
            if clock()>=next_memory:memory();next_memory=clock()+1
            if all(code is not None for code in codes):
                validation=namespace.pair([reader.terminal for reader in readers],context);break
            if clock()>=deadline:reason='cohort_deadline';break
            sleep(min(.05,max(0,deadline-clock())))
    except BaseException as caught:
        reason='cohort_deadline' if isinstance(caught,TimeoutError) else 'interrupted' if isinstance(caught,(KeyboardInterrupt,SystemExit)) else 'output_memory_or_startup_failure'
        error=type(caught).__name__+': '+str(caught)
    finally:
        if any(child.poll()is None for child in children):
            try:stop(ranks,children)
            except BaseException as caught:reason='cleanup_failed';error=repr(caught)
        for child in children:
            if child.poll()is not None:child.wait(timeout=0)
    codes=[child.poll() for child in children]
    result=dict(exit_codes=codes,supervisor_pids=[child.pid for child in children],
        supervisors_reaped=len(children)==2 and all(code is not None for code in codes),
        cancellation_reason=reason,error=error,validation=validation,
        passed=reason is None and codes==[0,0] and validation is not None,
        native_cleanup='delegated to unchanged rank_worker finally; independent PID inventory separate')
    return result,[reader.terminal for reader in readers]
