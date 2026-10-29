"""Bound one fixed read-only leader CLI command, outside the client timer."""
import hashlib
import json
import os
import selectors
import shlex
import signal
import subprocess
import time
from guards import SSH, REMOTE
from status_validation import MAXIMUM_STDOUT, validate

TIMEOUT_SECONDS = 15
MAXIMUM_STDERR = 16384


def private_write(path, value):
    with os.fdopen(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), 'wb') as stream:
        stream.write(value)


def bounded_command(command, timeout=TIMEOUT_SECONDS):
    started = time.monotonic()
    deadline = started + timeout
    process = None
    streams = selectors.DefaultSelector()
    raw = {'stdout': bytearray(), 'stderr': bytearray()}
    limits = {'stdout': MAXIMUM_STDOUT, 'stderr': MAXIMUM_STDERR}
    result = {'command': command, 'absoluteTimeoutSeconds': timeout,
              'remoteNativeCleanupProven': False, 'localProcessReaped': False}
    error = None
    try:
        process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, start_new_session=True)
        for name, pipe in [('stdout', process.stdout), ('stderr', process.stderr)]:
            os.set_blocking(pipe.fileno(), False)
            streams.register(pipe, selectors.EVENT_READ, name)
        while streams.get_map():
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError('Status command absolute deadline exceeded')
            for key, _ in streams.select(min(remaining, 0.1)):
                name = key.data
                try:
                    chunk = os.read(key.fileobj.fileno(), min(4096, limits[name] - len(raw[name]) + 1))
                except BlockingIOError:
                    continue
                if not chunk:
                    streams.unregister(key.fileobj)
                    continue
                available = limits[name] - len(raw[name])
                raw[name].extend(chunk[:available])
                if len(chunk) > available:
                    result[name + 'Truncated'] = True
                    raise ValueError('Status command output exceeded its bound')
        process.wait(timeout=max(0, deadline - time.monotonic()))
        if time.monotonic() > deadline:
            raise TimeoutError('Status command absolute deadline exceeded')
        if process.returncode != 0:
            raise RuntimeError('Status command returned nonzero')
    except BaseException as caught:
        error = caught
        result['error'] = type(caught).__name__ + ': ' + str(caught)
    finally:
        streams.close()
        if process is not None:
            if process.poll() is None:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                except BaseException as caught:
                    result['localFenceError'] = type(caught).__name__
                    if error is None:
                        error = caught
            try:
                process.wait(timeout=2)
                result['localProcessReaped'] = True
            except BaseException as caught:
                result['localCleanupError'] = type(caught).__name__
                if error is None:
                    error = caught
            for pipe in (process.stdout, process.stderr):
                if pipe is not None:
                    try:
                        pipe.close()
                    except BaseException as caught:
                        result['localPipeCleanupError'] = type(caught).__name__
                        if error is None:
                            error = caught
            result['localExitCode'] = process.returncode
        result['elapsedSeconds'] = time.monotonic() - started
    return bytes(raw['stdout']), bytes(raw['stderr']), result, error


def capture(output, phase, previous=None):
    if phase not in ('before', 'after') or (phase == 'after') != (previous is not None):
        raise ValueError('Invalid fixed status capture phase')
    command = SSH + ['darkbloom-24', shlex.join([REMOTE + '/darkbloom', 'cluster', 'status', '--json'])]
    raw, err, receipt, failure = bounded_command(command)
    # Raw outputs are bounded, private, and contain no auth command argument.
    private_write(output / ('status-' + phase + '.stdout.json'), raw)
    private_write(output / ('status-' + phase + '.stderr'), err)
    receipt.update(phase=phase, stdoutBytes=len(raw), stderrBytes=len(err),
                   stdoutSHA256=hashlib.sha256(raw).hexdigest(), stderrSHA256=hashlib.sha256(err).hexdigest(),
                   includedInClientTTFT=False)
    summary = None
    if failure is None:
        try:
            summary = validate(raw, previous=previous)
            receipt['validation'] = summary
        except BaseException as caught:
            failure = caught
            receipt['error'] = type(caught).__name__ + ': ' + str(caught)
    private_write(output / ('status-' + phase + '.receipt.json'),
                  (json.dumps(receipt, indent=2) + '\n').encode())
    if failure is not None:
        raise failure
    return summary
