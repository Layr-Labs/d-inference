"""Bounded nonblocking JSONL pipes for a persistent rank cohort."""

from collections import deque
import json
import os
from pathlib import Path
import selectors
import time


MAX_FRAME_BYTES = 32 * 1024 * 1024
MAX_QUEUED_FRAMES = 256
MAX_QUEUED_BYTES = 64 * 1024 * 1024


class PersistentCohortError(RuntimeError):
    pass


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False,
                      allow_nan=False).encode('utf-8')


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise PersistentCohortError(f'Duplicate native frame key: {key}')
        result[key] = value
    return result


class FrameIO:
    def __init__(self, processes, directories, cancellation):
        self.processes = processes
        self.cancellation = cancellation
        self.selector = selectors.DefaultSelector()
        self.buffers = [bytearray() for _ in processes]
        self.frames = [deque() for _ in processes]
        self.frame_bytes = [deque() for _ in processes]
        self.queued_bytes = 0
        self.scan_from = [0 for _ in processes]
        self.eof = [False for _ in processes]
        self.pending = [bytearray() for _ in processes]
        self.paused = [False for _ in processes]
        self.logs = []
        self.closed = False
        for rank, (process, directory) in enumerate(zip(processes, directories)):
            path = Path(directory) / 'stdout.jsonl'
            stream = path.open('wb')
            path.chmod(0o600)
            self.logs.append(stream)
            os.set_blocking(process.stdout.fileno(), False)
            os.set_blocking(process.stdin.fileno(), False)
            self.selector.register(process.stdout, selectors.EVENT_READ, ('read', rank))

    def _remaining(self, deadline):
        if self.cancellation.is_set() or self.closed:
            raise PersistentCohortError('Persistent epoch has been retired')
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise PersistentCohortError('Persistent cohort deadline expired')
        return remaining

    def _parse(self, rank):
        buffer = self.buffers[rank]
        while True:
            if len(self.frames[rank]) >= MAX_QUEUED_FRAMES:
                if not self.paused[rank] and not self.eof[rank]:
                    self.selector.unregister(self.processes[rank].stdout)
                    self.paused[rank] = True
                return
            newline = buffer.find(b'\n', self.scan_from[rank])
            if newline == -1:
                if len(buffer) > MAX_FRAME_BYTES:
                    raise PersistentCohortError('Native frame exceeds byte limit')
                self.scan_from[rank] = len(buffer)
                return
            if newline > MAX_FRAME_BYTES:
                raise PersistentCohortError('Native frame exceeds byte limit')
            raw = bytes(buffer[:newline])
            del buffer[:newline + 1]
            self.scan_from[rank] = 0
            if not raw:
                raise PersistentCohortError('Empty native protocol frame')
            if self.queued_bytes + len(raw) > MAX_QUEUED_BYTES:
                raise PersistentCohortError('Native frames exceed aggregate queued-byte limit')
            try:
                frame = json.loads(raw.decode('utf-8'), object_pairs_hook=unique_object,
                    parse_constant=lambda value: (_ for _ in ()).throw(PersistentCohortError(f'Nonfinite native JSON: {value}')))
            except (UnicodeError, json.JSONDecodeError) as error:
                raise PersistentCohortError('Malformed native JSONL frame') from error
            if not isinstance(frame, dict):
                raise PersistentCohortError('Native frame must be an object')
            self.frames[rank].append(frame)
            self.frame_bytes[rank].append(len(raw))
            self.queued_bytes += len(raw)

    def pump(self, deadline, poll_timeout=0.05):
        if deadline is None:
            # Idle observation has a bounded select wait, not a request
            # deadline. Scheduler suspension must not retire a healthy epoch.
            if self.cancellation.is_set() or self.closed:
                raise PersistentCohortError('Persistent epoch has been retired')
            wait = poll_timeout
        else:
            wait = min(self._remaining(deadline), poll_timeout)
        for key, _ in self.selector.select(timeout=wait):
            operation, rank = key.data
            try:
                if operation == 'write':
                    written = os.write(key.fileobj.fileno(), self.pending[rank])
                    del self.pending[rank][:written]
                    if not self.pending[rank]:
                        self.selector.unregister(key.fileobj)
                else:
                    chunk = os.read(key.fileobj.fileno(), 65536)
                    if not chunk:
                        self.eof[rank] = True
                        self.selector.unregister(key.fileobj)
                        if self.buffers[rank]:
                            raise PersistentCohortError('Truncated native JSONL frame at EOF')
                        continue
                    self.logs[rank].write(chunk)
                    self.logs[rank].flush()
                    self.buffers[rank].extend(chunk)
                    self._parse(rank)
            except BlockingIOError:
                continue
            except (BrokenPipeError, OSError, ValueError) as error:
                raise PersistentCohortError(f'Rank {rank} protocol pipe failed: {error}') from error

    def send(self, frame, deadline):
        self._remaining(deadline)
        payload = canonical(frame) + b'\n'
        if len(payload) - 1 > MAX_FRAME_BYTES:
            raise PersistentCohortError('Request exceeds protocol frame byte limit')
        for rank, process in enumerate(self.processes):
            if process.poll() is not None or self.eof[rank] or self.pending[rank]:
                raise PersistentCohortError(f'Rank {rank} cannot accept another frame')
            self.pending[rank].extend(payload)
            self.selector.register(process.stdin, selectors.EVENT_WRITE, ('write', rank))
        while any(self.pending):
            self.pump(deadline)

    def receive(self, rank, deadline):
        while True:
            self._remaining(deadline)
            if self.frames[rank]:
                value = self.frames[rank].popleft()
                self.queued_bytes -= self.frame_bytes[rank].popleft()
                self._parse(rank)
                if self.paused[rank] and len(self.frames[rank]) < MAX_QUEUED_FRAMES and not self.eof[rank]:
                    self.selector.register(self.processes[rank].stdout, selectors.EVENT_READ, ('read', rank))
                    self.paused[rank] = False
                return value
            # A fast worker can exit after writing its final stopped frame;
            # drain the pipe before interpreting EOF as a missing response.
            if self.eof[rank]:
                raise PersistentCohortError(f'Rank {rank} exited before its expected protocol frame')
            self.pump(deadline)

    def require_idle(self):
        if any(self.frames) or any(self.pending) or any(self.buffers):
            raise PersistentCohortError('Unsolicited native frames at request boundary')
        if any(self.eof) or any(p.poll() is not None for p in self.processes):
            raise PersistentCohortError('Native worker exited at request boundary')

    def close(self):
        if self.closed:
            return
        self.closed = True
        self.selector.close()
        for process in self.processes:
            for stream in (process.stdin, process.stdout):
                if stream:
                    stream.close()
        for stream in self.logs:
            stream.close()
