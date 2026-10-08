"""Serialized one-shot pair supervision; existing rank workers own native PGIDs."""

import time
from stage_lookahead_contract import RankRecords,require_timeout,validate_pair


def supervise(ranks,epoch,timeout,start,stop,memory_check,clock=time.monotonic,sleep=time.sleep):
    require_timeout(timeout)
    if [rank['rank'] for rank in ranks]!=[0,1]: raise ValueError('Expected two ordered ranks')
    readers=[RankRecords(rank['local'],rank['rank'],epoch,rank['inputs']) for rank in ranks]
    processes=[];reason=error=validation=None
    deadline=clock()+timeout;next_memory=clock()
    try:
        for rank in ranks:
            if clock()>=deadline: raise TimeoutError('Deadline expired during startup')
            processes.append(start(rank))
        while True:
            codes=[process.poll() for process in processes]
            for i,reader in enumerate(readers): reader.poll(final=codes[i]==0)
            if any(code is not None and code!=0 for code in codes): reason='rank_failed';break
            if clock()>=next_memory:
                memory_check();next_memory=clock()+1
            if all(code is not None for code in codes): validation=validate_pair(readers);break
            if clock()>=deadline: reason='cohort_deadline';break
            sleep(min(.05,max(0,deadline-clock())))
    except BaseException as caught:
        reason='cohort_deadline' if isinstance(caught,TimeoutError) else 'interrupted' if isinstance(caught,(KeyboardInterrupt,SystemExit)) else 'invalid_output_or_memory_or_startup'
        error=type(caught).__name__+': '+str(caught)
    finally:
        if any(process.poll()is None for process in processes):
            try: stop(ranks,processes)
            except BaseException as caught: reason='cleanup_failed';error=repr(caught)
        for process in processes:
            if process.poll()is not None: process.wait(timeout=0)
    codes=[process.poll() for process in processes]
    return dict(exit_codes=codes,supervisor_pids=[p.pid for p in processes],
        supervisors_reaped=len(processes)==2 and all(code is not None for code in codes),
        cancellation_reason=reason,error=error,validation=validation,
        passed=reason is None and codes==[0,0] and validation is not None,
        native_group_cleanup='existing rank_worker finally; root performs independent PID inventory')
