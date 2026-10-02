"""Bounded invocation through the existing reviewed unreaped-child helper."""
import contextlib
import io
import json
from pathlib import Path
import subprocess
import time
from owned_process import invoke_controller


def run_owned(argv, output, name, timeout):
    output = Path(output)
    record = {'argv': argv, 'timeoutSeconds': timeout, 'timedOut': False}
    start = time.monotonic()
    try:
        with (output / (name + '.stdout')).open('xb') as stdout, (output / (name + '.stderr')).open('xb') as stderr:
            with contextlib.redirect_stdout(io.StringIO()) as observation:
                invoke_controller(argv, stdout, stderr, record, timeout=timeout)
            record['launchObservation'] = observation.getvalue()
    except BaseException as error:
        record['timedOut'] = isinstance(error, subprocess.TimeoutExpired)
        raise
    finally:
        record['elapsedSeconds'] = time.monotonic() - start
        (output / (name + '.json')).write_text(json.dumps(record, indent=2, sort_keys=True) + '\n')
    if any((output / (name + '.' + suffix)).stat().st_size > 4_194_304 for suffix in ('stdout', 'stderr')):
        raise ValueError('Diagnostic output exceeds cap')
    if record.get('exitCode') != 0 or record['timedOut'] or not record.get('reaped') or not record.get('groupAbsent'):
        raise ValueError(name + ' failed; raw evidence retained')
    return record
