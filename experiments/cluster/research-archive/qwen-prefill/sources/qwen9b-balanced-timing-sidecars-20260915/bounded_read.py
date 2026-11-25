"""Exact reviewed bounded subprocess reader; larger cap for four JSON sidecars."""
import os, selectors, signal, subprocess, time
TIMEOUT_SECONDS=30
MAXIMUM_STDOUT=96*1024*1024
MAXIMUM_STDERR=16384

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

