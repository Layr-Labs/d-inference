"""One native owner, original absolute deadline through stdout/exit, exact cleanup."""
import os
import signal
import time
from binding_common import require
from gemma_inputs import write_json
from gemma_result import result as validate_result
from worker_processes import PipeWorkers, cleanup_error_text
from jaccl_startup_stderr import JacclStartupProgress, validate_retained


def group_observations(children):
    rows=[]
    for child in children:
        try: os.killpg(child.pid,0); absent=False
        except ProcessLookupError: absent=True
        rows.append(dict(pid=child.pid,pgid=child.pid,absent=absent))
    return rows


def serve(spec,run,started,gate,pins,postflight,mode,expected):
    deadline=started+315; pipes=None; primary=None; previous={}
    record=dict(schema='gemma_short_native_terminal_v1',mode=mode,status='starting',primaryFailure=None,
        postflightErrors=[],cleanupErrors=[],nativeResult=None,nativeLeaderReaped=False,ownedGroupsAbsent=False,
        outputComplete=False,sourceInputsUnchanged=False,journalEmptyAfterExit=False,processInventoryClear=False,
        numericalComparisonPerformed=False,throughputMeasurementValid=False,encryptedRDMAEstablished=False,
        protocolOwnerLeaseReleaseObserved=False,journalMutationPerformed=False)
    def guard(phase):
        require(time.monotonic()<deadline,'Original 315s parent deadline expired')
        gate(phase);require(time.monotonic()<deadline,'Resource sample exhausted deadline')
    def interrupted(number,_): raise SystemExit(128+number)
    def secondary(name,error):
        nonlocal primary
        record['postflightErrors'].append(dict(operation=name,error=cleanup_error_text(error)[0]))
        if primary is None or not isinstance(error,Exception):primary=error
    try:
        for n in (signal.SIGHUP,signal.SIGINT,signal.SIGTERM):previous[n]=signal.getsignal(n);signal.signal(n,interrupted)
        guard('prelaunch');seconds=int(deadline-time.monotonic())
        require(seconds>=301,'No room for native 300s alarm plus cleanup within original parent')
        stderr_policy=JacclStartupProgress() if mode=='stage1' else None
        pipes=PipeWorkers((spec,),run/'native',seconds,guard,stderr_policy=stderr_policy);pipes.start()
        write_json(run/'owner.json',dict(nativePIDs=[p.pid for p in pipes.children],nativePGIDs=[p.pid for p in pipes.children],
            supervisorPID=os.getpid(),nativeArgv=list(spec.argv),nativeEnvironment=spec.env,
            nativeAlarmSeconds=300,nativeAlarmEndsBeforeFinalStdout=True,parentDeadlineMonotonic=deadline,
            remainingGroupWatchdogSeconds=seconds,absoluteFenceCoversFinalStdout=True))
        record['nativeResult']=pipes.collect('native-report',lambda _,raw:validate_result(raw,mode,expected))[0]
        pipes.finish()
        record['stderrProgress']=(stderr_policy.summary() if stderr_policy is not None
            else validate_retained(b'',mode))
        guard('native-completed');record['status']='completed'
    except BaseException as error:
        primary=error;record['status']='failed';record['primaryFailure']=cleanup_error_text(error)[0]
    finally:
        if pipes is not None:
            try:pipes.close(kill=record['status']!='completed')
            except BaseException as error:secondary('owned_native_cleanup',error)
            record.update(nativePIDs=[p.pid for p in pipes.children],nativeExitCodes=[p.returncode for p in pipes.children],
                nativeLeaderReaped=bool(pipes.children) and all(p.returncode is not None for p in pipes.children),
                outputComplete=pipes.complete_output,cleanupErrors=list(pipes.cleanup_errors),watchdogExpired=pipes.expired.is_set())
            for name,callback in [('groups',lambda:group_observations(pipes.children)),('streams',pipes.retained_streams)]:
                try:
                    value=callback();record[name]=value
                    if name=='groups':record['ownedGroupsAbsent']=bool(value) and all(x['absent'] for x in value)
                except BaseException as error:secondary(name,error)
        for name,callback in [('source',pins.recheck),('resource',lambda:gate('postflight')),('physical',postflight)]:
            try:
                value=callback()
                if name=='source':record['sourceInputsUnchanged']=True
                if name=='physical':
                    record['postflight']=value;record['journalEmptyAfterExit']=record['processInventoryClear']=True
            except BaseException as error:secondary(name,error)
        if time.monotonic()>=deadline:record['postflightErrors'].append(dict(operation='deadline',error='Original 315s lifetime exhausted'))
        if (record['postflightErrors'] or record['cleanupErrors'] or record.get('nativeExitCodes')!=[0]
            or not all(record[k] for k in ('nativeLeaderReaped','ownedGroupsAbsent','outputComplete','sourceInputsUnchanged',
                                           'journalEmptyAfterExit','processInventoryClear'))):record['status']='failed'
        record['elapsedSeconds']=time.monotonic()-started
        try:write_json(run/'terminal.json',record)
        finally:
            for n,handler in previous.items():signal.signal(n,handler)
    if primary is not None and not isinstance(primary,Exception):raise primary
    return record
