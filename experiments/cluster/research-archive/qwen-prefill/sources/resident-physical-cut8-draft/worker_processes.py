"""Owned POSIX pipe processes with bounded retained output and hard group expiry."""

import hashlib
import os
from pathlib import Path
import selectors
import signal
import subprocess
import threading
import time

from worker_contract import MAX_LINE, MAX_OUTPUT, encoded, require


def cleanup_error_text(error):
    """Bound diagnostic text without trusting a cleanup exception's __str__."""
    formatting_error = None
    try:
        detail = str(error)
    except BaseException as failure:
        formatting_error = failure
        detail = 'message unavailable (%s)' % type(failure).__name__
    text = (type(error).__name__ + ': ' + detail).replace('\0', '\\0')
    return text.encode('utf-8', errors='replace')[:2048].decode('utf-8', errors='ignore'), formatting_error


class PipeWorkers:
    def __init__(self, specs, directory, timeout_seconds, resource_gate):
        require(type(timeout_seconds) is int and 1 <= timeout_seconds <= 315, "Worker lifetime must be1...315seconds")
        require(callable(resource_gate), "Resource gate is required")
        self.specs, self.directory = specs, Path(directory)
        self.timeout, self.resource_gate = timeout_seconds, resource_gate
        self.selector = selectors.DefaultSelector()
        self.children, self.logs, self.buffers, self.events, self.writes = [], {}, {}, {}, {}
        self.eof, self.expired = set(), threading.Event()
        self.total_output = 0
        self.started = None
        self.timer = None
        self.closed = False
        self._retiring = self._closing = False
        self._cleanup_interrupt = None
        # A reaped leader does not establish retirement of its process group.
        # Entries mean SIGKILL was accepted for the group, or it was absent.
        self._fenced_groups = set()
        self.complete_output = False
        self.cleanup_errors = []
        self._lock = threading.Lock()

    def start(self):
        self.started = time.monotonic()
        self.timer = threading.Timer(self.timeout, self._expire)
        self.timer.daemon = True
        self.timer.start()
        os.mkdir(self.directory, 0o700)
        for index, spec in enumerate(self.specs):
            self.check()
            for stream in ('stdin', 'stdout', 'stderr'):
                path = self.directory / ('worker-%d.%s' % (index, stream))
                descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
                self.logs[index, stream] = os.fdopen(descriptor, 'wb', buffering=0)
            with self._lock:
                child = subprocess.Popen(spec.argv, env=spec.env, stdin=subprocess.PIPE,
                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0, start_new_session=True)
                self.children.append(child)
            self.buffers[index], self.events[index], self.writes[index] = bytearray(), [], bytearray()
            for stream in ('stdin', 'stdout', 'stderr'):
                handle = getattr(child, stream)
                os.set_blocking(handle.fileno(), False)
                if stream != 'stdin':
                    self.selector.register(handle, selectors.EVENT_READ, (index, stream))
            self.check()

    def _kill_groups(self):
        with self._lock:
            children = list(self.children)
        for child in children:
            if child.pid in self._fenced_groups:
                continue
            try:
                os.killpg(child.pid, signal.SIGKILL)
            except ProcessLookupError:
                self._fenced_groups.add(child.pid)
            except BaseException as error:
                self._note_cleanup_error('killpg:%s' % child.pid, error)
            else:
                self._fenced_groups.add(child.pid)

    def _confirm_groups_absent(self):
        with self._lock:
            children = list(self.children)
        for child in children:
            if child.pid in self._fenced_groups:
                continue
            try:
                os.killpg(child.pid, 0)
            except ProcessLookupError:
                self._fenced_groups.add(child.pid)
            except BaseException as error:
                self._note_cleanup_error('probe-group:%s' % child.pid, error)
            else:
                self._note_cleanup_error('probe-group:%s' % child.pid,
                                         RuntimeError('Owned group remains after graceful worker exit'))

    def _note_cleanup_error(self, label, error):
        # Preserve an operator interruption before formatting can itself fail.
        if not isinstance(error, Exception) and self._cleanup_interrupt is None:
            self._cleanup_interrupt = error
        text, formatting_error = cleanup_error_text(error)
        if (formatting_error is not None and not isinstance(formatting_error, Exception)
                and self._cleanup_interrupt is None):
            self._cleanup_interrupt = formatting_error
        self.cleanup_errors.append(label + ':' + text)

    def _expire(self):
        if self.closed:
            return
        self.expired.set()
        self._kill_groups()

    def check(self):
        require(not self.closed and not self._retiring, 'Worker supervisor has been closed or is retiring')
        if self.expired.is_set() or (self.started is not None and time.monotonic() - self.started >= self.timeout):
            self._expire()
            raise TimeoutError('Resident worker lifetime expired')

    def gate(self, phase):
        self.check()
        require(self.resource_gate(phase) is None, 'Resource gate must return None on success or raise')
        self.check()

    def send(self, command):
        self.check()
        # Refuse complete or partial output already observed before permission.
        # The sole allowed result4->released transition sends no new command.
        self.pump('before-command', wait_seconds=0)
        require(not any(self.events.values()) and not any(self.buffers.values()), 'Unsolicited output before command')
        raw = encoded(command)
        for index, child in enumerate(self.children):
            require(not self.writes[index], 'Previous worker command is still pending')
            require(child.poll() is None, 'Worker exited before command')
            self.writes[index].extend(raw)
            self.selector.register(child.stdin, selectors.EVENT_WRITE, (index, 'stdin'))
        # Outputs can arrive while another pipe is writing. Retain them, but do
        # not validate any event until every complete command has been written.
        while any(self.writes.values()):
            self.pump('command-write')

    def _retain(self, index, stream, raw):
        remaining = MAX_OUTPUT - self.total_output
        retained = raw[:remaining]
        if retained:
            self._write_all(self.logs[index, stream], retained)
            self.total_output += len(retained)
        require(len(raw) <= remaining, 'Combined stdout/stderr exceeds160MiB; retained prefix only')

    @staticmethod
    def _write_all(handle, raw):
        remaining = memoryview(raw)
        while remaining:
            count = handle.write(remaining)
            require(type(count) is int and count > 0, 'Retained stream write did not advance')
            remaining = remaining[count:]

    def _read(self, index, stream, handle):
        raw = os.read(handle.fileno(), 65536)
        if not raw:
            self.selector.unregister(handle)
            self.eof.add((index, stream))
            if stream == 'stdout':
                require(not self.buffers[index], 'Worker stdout ended without final LF')
            return
        if stream == 'stderr':
            self._retain(index, stream, raw)
            raise ValueError('Unexpected worker stderr')
        # Retain only the exact bounded prefix if a stream violates a cap.
        pieces = raw.split(b'\n')
        for part, piece in enumerate(pieces):
            buffer = self.buffers[index]
            allowed = MAX_LINE - len(buffer)
            prefix = piece[:allowed]
            self._retain(index, stream, prefix)
            buffer.extend(prefix)
            require(len(piece) <= allowed, 'Worker output line exceeds32MiB; retained prefix only')
            if part < len(pieces) - 1:
                self._retain(index, stream, b'\n')
                require(len(self.events[index]) < 8, 'Too many pending worker events')
                self.events[index].append(bytes(buffer))
                buffer.clear()

    def pump(self, phase, wait_seconds=None):
        self.gate(phase)
        wait = max(0.0, min(0.05, self.timeout - (time.monotonic() - self.started)))
        if wait_seconds is not None:
            wait = min(wait, wait_seconds)
        for key, _ in self.selector.select(wait):
            index, stream = key.data
            if stream == 'stdin':
                pending = self.writes[index]
                count = os.write(key.fileobj.fileno(), pending)
                require(count > 0, 'Worker stdin write did not advance')
                self._write_all(self.logs[index, 'stdin'], pending[:count])
                del pending[:count]
                if not pending:
                    self.selector.unregister(key.fileobj)
            else:
                self._read(index, stream, key.fileobj)
        self.check()

    def collect(self, phase, validate):
        require(not any(self.writes.values()), 'Events cannot validate before all commands are written')
        values, received = [None] * len(self.children), set()
        while len(received) < len(self.children):
            for index in range(len(self.children)):
                if index in received:
                    continue
                if self.events[index]:
                    self.check()
                    values[index] = validate(index, self.events[index].pop(0))
                    self.check()
                    received.add(index)
                else:
                    require((index, 'stdout') not in self.eof, 'Worker EOF before expected event')
            if len(received) < len(self.children):
                self.pump(phase)
        self.check()
        return values

    def finish(self):
        while True:
            require(not any(self.events.values()), 'Unexpected trailing worker event')
            if len(self.eof) == 2 * len(self.children) and all(child.poll() is not None for child in self.children):
                break
            self.pump('shutdown-wait')
        require(all(child.returncode == 0 for child in self.children), 'Worker exit was nonzero')
        require(not any(self.writes.values()), 'Worker exited before shutdown command was written')
        self.close(kill=False)
        require(not self.cleanup_errors, 'Worker successful-exit cleanup failed')
        self.complete_output = True

    def close(self, kill=True):
        if self.closed or self._closing:
            return
        self._retiring = self._closing = True
        def attempt(label, action):
            try:
                action()
                return True
            except BaseException as error:
                self._note_cleanup_error(label, error)
                return False
        try:
            # The watchdog remains active while each initial kill and reap is
            # attempted. One kill interruption cannot skip the other groups.
            if kill:
                self._kill_groups()
            for child in self.children:
                if not attempt('reap:%s' % child.pid, lambda: child.wait(timeout=1)):
                    self._kill_groups()
                    attempt('reap-retry:%s' % child.pid, lambda: child.wait(timeout=1))
                for stream in ('stdin', 'stdout', 'stderr'):
                    attempt('close-pipe:%s' % stream, getattr(child, stream).close)
            if not kill:
                self._confirm_groups_absent()
            # Retry unresolved fences independently of leader wait results.
            # Graceful exit with a surviving group is already a cleanup error;
            # still attempt to kill it before returning that failure.
            self._kill_groups()
            selector_closed = attempt('close-selector', self.selector.close)
            for handle in self.logs.values():
                attempt('close-log', handle.close)
            retired = all(child.returncode is not None for child in self.children)
            groups_fenced = all(child.pid in self._fenced_groups for child in self.children)
            handles_closed = all(getattr(child, stream).closed for child in self.children
                                 for stream in ('stdin', 'stdout', 'stderr'))
            self.closed = (retired and groups_fenced and handles_closed and selector_closed
                           and all(handle.closed for handle in self.logs.values()))
            if retired and groups_fenced and self.timer is not None:
                attempt('cancel-watchdog', self.timer.cancel)
            # If a leader or group remains unresolved, retain the watchdog.
            # New work stays refused, but a later close may retry teardown.
        finally:
            self._closing = False
        if self._cleanup_interrupt is not None:
            raise self._cleanup_interrupt

    def retained_streams(self):
        """Only call after closure; hashes cover retained bytes, possibly a prefix."""
        require(self.closed, 'Stream snapshots require closed logs')
        result = []
        for index, stream in sorted(self.logs):
            path = self.directory / ('worker-%d.%s' % (index, stream))
            digest = hashlib.sha256()
            with path.open('rb') as handle:
                for chunk in iter(lambda: handle.read(65536), b''):
                    digest.update(chunk)
            result.append(dict(worker=index, stream=stream, path=str(path), bytes=path.stat().st_size,
                               sha256=digest.hexdigest()))
        return result
