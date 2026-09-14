"""Bound subprocess output and retain partial diagnostics on interruption."""
import os
import signal
import subprocess
import threading
import time


def capture(argv, *, cwd=None, env=None, timeout=300, limit=8 * 1024 * 1024):
    if timeout <= 0 or limit <= 0:
        raise ValueError('capture bounds must be positive')
    streams = {'stdout': bytearray(), 'stderr': bytearray()}
    overflow = threading.Event()
    started = time.monotonic()
    process = subprocess.Popen([str(item) for item in argv], cwd=cwd, env=env,
                               stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               start_new_session=True)

    def drain(name, pipe):
        try:
            while chunk := pipe.read(65536):
                remaining = limit - len(streams[name])
                streams[name].extend(chunk[:max(remaining, 0)])
                if len(chunk) > remaining:
                    overflow.set()
        finally:
            pipe.close()

    readers = [threading.Thread(target=drain, args=(name, getattr(process, name)), daemon=True) for name in streams]
    for reader in readers:
        reader.start()
    interrupted = False
    interruption_error = None
    try:
        while process.poll() is None:
            if overflow.is_set() or time.monotonic() - started >= timeout:
                interrupted = True
                break
            time.sleep(0.02)
    except BaseException as error:
        interrupted, interruption_error = True, error
    finally:
        if process.poll() is None:
            # CLI SIGINT requests cancellation of its own accepted command.
            # Each process belongs to this capture's separate process group.
            process.send_signal(signal.SIGINT)
            try:
                process.wait(timeout=12)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                process.wait(timeout=5)
        for reader in readers:
            reader.join(timeout=1)
        if any(reader.is_alive() for reader in readers):
            interrupted = True
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            for reader in readers:
                reader.join(timeout=5)
        if any(reader.is_alive() for reader in readers):
            raise RuntimeError('owned subprocess output pipes did not close')
    return {'stdout': bytes(streams['stdout']), 'stderr': bytes(streams['stderr']),
            'returncode': process.returncode, 'wall_seconds': time.monotonic() - started,
            'interrupted': interrupted, 'capture_truncated': overflow.is_set(),
            'interruption_error': interruption_error}


def failed(result):
    return result['returncode'] != 0 or result['interrupted'] or result['capture_truncated']
