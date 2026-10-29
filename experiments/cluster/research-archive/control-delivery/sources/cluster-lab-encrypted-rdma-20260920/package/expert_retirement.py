"""Drain/reap the existing owned child before interpreting numerical success."""
from binding_common import require


def collect_retired_result(pipes, parse_result):
    require(len(pipes.children)==1,'Expert result retirement requires exactly one owned child')
    value = pipes.collect('benchmark', parse_result)[0]
    # Exact PipeWorkers.finish drain/poll ordering. Only its zero-exit check is
    # deferred until AFTER close and numerical result inspection by the caller.
    # The same gate, selector, absolute watchdog and owned-group rules apply.
    while True:
        require(not any(pipes.events.values()), 'Unexpected trailing worker event')
        if len(pipes.eof) == 2 * len(pipes.children) and all(pipes._poll(child) is not None for child in pipes.children):
            break
        pipes.pump('shutdown-wait')
    require(not any(pipes.writes.values()), 'Worker exited before shutdown command was written')
    exit_codes = [child.returncode for child in pipes.children]
    pipes.close(kill=False)
    require(not pipes.cleanup_errors and pipes.closed, 'Worker result-retirement cleanup failed')
    pipes.complete_output = True
    return value, exit_codes
