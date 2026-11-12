"""One bounded read-only SSH call; injected process/selector seams support fake tests."""
import os
import selectors
import shlex
import signal
import subprocess
import time
from sidecar_files import MAX_SIDECAR, require

TIMEOUT_SECONDS = 20
MAX_STDOUT, MAX_STDERR = MAX_SIDECAR + 4097, 16 * 1024


class SSHReadFailure(Exception):
    def __init__(self, primary, cleanup, observation, stdout, stderr):
        super().__init__(primary['error'])
        self.primary, self.cleanup, self.observation = primary, cleanup, observation
        self.stdout, self.stderr = stdout, stderr


def command(host, path, payload):
    return ['ssh', '-T', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=5',
            '-o', 'ServerAliveInterval=5', '-o', 'ServerAliveCountMax=2', host,
            shlex.join(['/usr/bin/python3', '-c', payload, path])]


def read_over_ssh(host, path, payload, *, popen=None,
                  selector_factory=selectors.DefaultSelector, clock=time.monotonic,
                  read=os.read, killpg=os.killpg):
    child, selector, primary, reaped = None, None, None, False
    cleanup, buffers = [], {'stdout': bytearray(), 'stderr': bytearray()}
    caps = {'stdout': MAX_STDOUT, 'stderr': MAX_STDERR}
    started = clock()
    try:
        popen = popen or subprocess.Popen
        child = popen(command(host, path, payload), stdin=subprocess.DEVNULL,
                      stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
        selector = selector_factory()
        for name in buffers:
            selector.register(getattr(child, name), selectors.EVENT_READ, name)
        while selector.get_map():
            remaining = started + TIMEOUT_SECONDS - clock()
            require(remaining > 0, 'Read-only SSH exceeded its 20 second deadline')
            for key, _ in selector.select(min(.1, remaining)):
                name = key.data
                data = read(key.fileobj.fileno(), min(65536, caps[name] + 1 - len(buffers[name])))
                if not data:
                    selector.unregister(key.fileobj)
                    continue
                buffers[name].extend(data)
                require(len(buffers[name]) <= caps[name], 'Read-only SSH ' + name + ' exceeded its byte cap')
        remaining = started + TIMEOUT_SECONDS - clock()
        require(remaining > 0, 'Read-only SSH deadline expired after output EOF')
        code = child.wait(timeout=remaining)
        reaped = True
        require(code == 0, 'Read-only SSH or remote reader exited nonzero: ' + str(code))
        require(not buffers['stderr'], 'Read-only SSH or remote reader emitted stderr')
    except BaseException as error:
        primary = dict(operation='read_owned_remote_sidecar', error=type(error).__name__ + ': ' + str(error))
    finally:
        if child is not None and not reaped:
            try:
                if child.poll() is None:
                    killpg(child.pid, signal.SIGKILL)
            except BaseException as error:
                cleanup.append(dict(operation='kill_local_reader_ssh_group', error=repr(error)))
            try:
                child.wait(timeout=2)
                reaped = True
            except BaseException as error:
                cleanup.append(dict(operation='reap_local_reader_ssh_client', error=repr(error)))
        if selector is not None:
            try:
                selector.close()
            except BaseException as error:
                cleanup.append(dict(operation='close_local_selector', error=repr(error)))
        if child is not None:
            for name in buffers:
                try:
                    getattr(child, name).close()
                except BaseException as error:
                    cleanup.append(dict(operation='close_local_' + name, error=repr(error)))
    observation = dict(local_reader_ssh_client_pid=child.pid if child is not None else None,
        local_reader_ssh_client_reaped=reaped, remote_process_reaping_verified=False,
        elapsed_local_monotonic_seconds=max(0, clock() - started), timeout_seconds=TIMEOUT_SECONDS,
        cleanup_wait_bound_seconds=2, stdout_observed_bytes=len(buffers['stdout']),
        stderr_observed_bytes=len(buffers['stderr']), stdout_cap_bytes=MAX_STDOUT, stderr_cap_bytes=MAX_STDERR)
    stdout, stderr = bytes(buffers['stdout']), bytes(buffers['stderr'])
    if primary is not None or cleanup:
        raise SSHReadFailure(primary or dict(operation='reader_cleanup', error='SSH cleanup failed'),
                             cleanup, observation, stdout, stderr)
    return stdout, stderr, observation
