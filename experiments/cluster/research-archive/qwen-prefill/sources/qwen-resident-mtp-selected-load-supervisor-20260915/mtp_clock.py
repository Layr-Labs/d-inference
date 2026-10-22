"""Owned actual-binary Swift uptime sampling; no Python absolute-clock conversion."""
import time

from binding_common import require
from mtp_inputs import native_environment, path, write_json
from worker_contract import WorkerSpec, workers
from worker_processes import PipeWorkers, cleanup_error_text


def swift_clock(job, run, guard, timeout=5):
    spec = workers([WorkerSpec((str(path(job['deployment'])/'MTPSelectedLoadCheck'), 'clock'),
                              native_environment(run), 'solo', None)])[0]
    return sample_clock(spec, run, guard, timeout=timeout)


def sample_clock(spec, run, guard, timeout=5):
    """The injected command seam is used only by fabricated-child CPU tests."""
    require(type(timeout) is int and 1 <= timeout <= 5, 'Swift clock process bound must be1...5seconds')
    pipes = PipeWorkers((spec,), run/'clock-process', timeout, guard)
    primary = None
    result = dict(schema='private_swift_uptime_sample_v1', status='failed')
    started = time.monotonic()
    try:
        pipes.start()
        result['owner'] = dict(pid=pipes.children[0].pid, pgid=pipes.children[0].pid,
                               argv=list(spec.argv), environment=dict(spec.env))
        write_json(run/'clock-owner.json', result['owner'])
        def decode(_, raw):
            require(1 <= len(raw) <= 20 and raw.isdigit(), 'Swift clock must be one unsigned decimal line')
            value = int(raw)
            require(0 < value <= 2**64-1-300_000_000_000 and str(value).encode() == raw,
                    'Swift clock must be positive canonical UInt64 with lifetime headroom')
            return value
        result['uptimeNanoseconds'] = pipes.collect('clock-uptime', decode)[0]
        pipes.finish()
        result['status'] = 'completed'
    except BaseException as error:
        primary = error; result['failure'] = cleanup_error_text(error)[0]
    finally:
        try:
            pipes.close(kill=result['status'] != 'completed')
        except BaseException as error:
            result['cleanupFailure'] = cleanup_error_text(error)[0]
            if primary is None or (not isinstance(error, Exception) and isinstance(primary, Exception)):
                primary = error
        result['exitCodes'] = [p.returncode for p in pipes.children]
        result['reaped'] = bool(pipes.children) and all(p.returncode is not None for p in pipes.children)
        result['groupFenced'] = bool(pipes.children) and all(p.pid in pipes._fenced_groups for p in pipes.children)
        result['completeOutput'] = pipes.complete_output
        result['cleanupErrors'] = list(pipes.cleanup_errors)
        result['elapsedSeconds'] = time.monotonic()-started
        try:
            result['streams'] = pipes.retained_streams()
        except BaseException as error:
            if primary is None:
                primary = error
            result['streamFailure'] = cleanup_error_text(error)[0]
        if (primary is not None or result['cleanupErrors'] or not result['reaped']
                or not result['groupFenced'] or not result['completeOutput'] or result['exitCodes'] != [0]):
            result['status'] = 'failed'
        write_json(run/'clock-terminal.json', result)
    if primary is not None:
        raise primary
    require(result['status'] == 'completed', 'Swift clock process did not complete safely')
    return result['uptimeNanoseconds']
