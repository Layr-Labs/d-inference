"""Persistent native model workers with one cancellable epoch and serial requests.

No request is retried. Protocol/worker/callback failure permanently fences the
whole cohort. A Python callback cannot be forcibly stopped; a daemon callback
thread is abandoned at the request deadline and no later callback is dispatched.
"""

import copy
import json
from pathlib import Path
import threading
import time
import uuid

from .configuration import validate
from .persistent_io import FrameIO, PersistentCohortError
from . import persistent_protocol as protocol
from .processes import stop_processes
from .persistent_processes import prepare, start as start_process
from .persistent_request import run_request



class PersistentCohort:
    def __init__(self, spec, bundle: Path, output: Path):
        self.spec = validate(copy.deepcopy(spec))
        if self.spec['backend'] == 'replicas':
            raise ValueError('PersistentCohort requires solo or an explicit cooperative backend; use separate solo cohorts for replicas')
        self.bundle, self.output = Path(bundle).resolve(), Path(output).resolve()
        repository = Path(__file__).resolve().parents[3]
        if self.output.is_relative_to(repository) or self.output.exists():
            raise ValueError('Persistent output must be a new directory outside the repository')
        self._epoch = uuid.uuid4().hex
        self._initial_epoch = self._epoch
        self._state = 'new'
        self._ready = []
        self._ranks, self._processes = [], []
        self._io = None
        self._sequence = 0
        self._request_ids = set()
        self._operation = threading.Lock()
        self._state_lock = threading.RLock()
        self._cleanup_lock = threading.Lock()
        self._cancellation = threading.Event()
        self._monitor_stop = threading.Event()
        self._retired = False
        self._manifest = dict(version=1, epoch=self._initial_epoch, spec=self.spec, requests=[])

    @property
    def epoch(self):
        with self._state_lock:
            return self._epoch

    @property
    def state(self):
        with self._state_lock:
            return self._state

    @property
    def ready(self):
        with self._state_lock:
            return copy.deepcopy(self._ready)

    @property
    def workerPIDs(self):
        with self._state_lock:
            return [record['pid'] for record in self._ready]

    def _save(self):
        with self._state_lock:
            if not self.output.exists():
                return
            self._manifest['state'] = self._state
            path = self.output / 'session.json'
            temporary = self.output / 'session.json.tmp'
            temporary.write_text(json.dumps(self._manifest, indent=2, allow_nan=False) + '\n')
            temporary.chmod(0o600)
            temporary.replace(path)

    def _check_live(self):
        if self._cancellation.is_set() or self._epoch is None:
            raise PersistentCohortError('Persistent epoch has been retired')

    def _watch_idle(self):
        while not self._monitor_stop.wait(0.05):
            error = None
            with self._state_lock:
                if self._state == 'idle':
                    try:
                        # State ownership excludes foreground pipe operations;
                        # a short poll also fences unsolicited idle output/EOF.
                        self._io.pump(None, poll_timeout=0.01)
                        self._io.require_idle()
                    except BaseException as failure:
                        error = str(failure)
            if error is not None:
                self._fail('Idle worker failed: ' + error)
                return

    def start(self):
        if not self._operation.acquire(blocking=False):
            raise PersistentCohortError('Another cohort operation is active')
        try:
            with self._state_lock:
                if self._state == 'idle':
                    return self.ready
                if self._state != 'new':
                    raise PersistentCohortError('This persistent cohort cannot be started again')
                self._state = 'starting'
            self.output.mkdir(parents=True, mode=0o700, exist_ok=False)
            self._save()
            digest, self._ranks = prepare(self.spec, self.bundle, self.output, self._initial_epoch, self._check_live)
            self._manifest.update(bundle_manifest_sha256=digest, ranks=self._ranks)
            self._save()
            # Bundle staging uses the existing bounded copy/SSH timeouts. The
            # native startup deadline starts when the cohort is launched.
            deadline = time.monotonic() + self.spec['timeout_seconds'] + 5
            for rank in self._ranks:
                with self._state_lock:
                    self._check_live()
                    self._processes.append(start_process(rank))
            with self._state_lock:
                self._check_live()
                self._io = FrameIO(self._processes, [r['local'] for r in self._ranks], self._cancellation)
            ready = [protocol.ready(self._io.receive(rank, deadline), self._initial_epoch, rank, self.spec)
                     for rank in range(len(self._ranks))]
            for record in ready[1:]:
                protocol.same(record['identity'], ready[0]['identity'], 'rank identity agreement')
                protocol.same(record['limits'], ready[0]['limits'], 'rank limits agreement')
            self._io.require_idle()
            with self._state_lock:
                self._check_live()
                self._ready = ready
                self._state = 'idle'
                self._manifest['ready'] = ready
            self._save()
            threading.Thread(target=self._watch_idle, daemon=True, name='persistent-idle-monitor').start()
            return self.ready
        except BaseException as error:
            self._fail(str(error))
            if isinstance(error, (KeyboardInterrupt, SystemExit, PersistentCohortError)):
                raise
            raise PersistentCohortError(f'Persistent startup failed: {error}') from error
        finally:
            self._operation.release()

    def _callback_live(self):
        with self._state_lock:
            self._check_live()

    def infer(self, request_id, prompt, output_tokens, chunk_size, teacher_tokens=None,
              capture_logits=False, timeout_seconds=30, on_token=None):
        if not self._operation.acquire(blocking=False):
            raise PersistentCohortError('Persistent requests are serialized; another operation is active')
        active = False
        try:
            with self._state_lock:
                if self._state != 'idle':
                    raise PersistentCohortError('Persistent cohort is not idle and reusable')
                self._check_live()
                if on_token is not None and not callable(on_token):
                    raise ValueError('on_token must be callable')
                command = protocol.request(self._epoch, self._sequence + 1, request_id, prompt,
                    output_tokens, chunk_size, teacher_tokens, capture_logits, timeout_seconds, self._ready[0])
                if request_id in self._request_ids:
                    raise ValueError('request_id was already used in this epoch')
                self._request_ids.add(request_id)
                self._state = 'busy'
                self._sequence += 1
                active = True
            deadline = time.monotonic() + timeout_seconds
            self._io.require_idle()
            self._manifest['requests'].append(dict(sequence=command['sequence'], requestID=request_id,
                requestSHA256=protocol.hash_frame(command), status='active'))
            self._save()
            completed = run_request(self._io, command, self._ready, deadline, on_token, self._callback_live)
            self._io.require_idle()
            with self._state_lock:
                self._check_live()
                self._state = 'idle'
                self._manifest['requests'][-1]['status'] = 'completed'
            self._save()
            return completed
        except BaseException as error:
            if active:
                self._fail(str(error))
            if isinstance(error, (KeyboardInterrupt, SystemExit, PersistentCohortError, ValueError)):
                raise
            raise PersistentCohortError(f'Persistent request failed: {error}') from error
        finally:
            self._operation.release()

    def _retire(self):
        with self._cleanup_lock:
            if self._retired:
                return
            self._monitor_stop.set()
            if self._processes:
                stop_processes(self._ranks, self._processes)
            if self._io:
                self._io.close()
            else:
                for process in self._processes:
                    for pipe in (process.stdin, process.stdout):
                        if pipe:
                            pipe.close()
            self._retired = True

    def _fail(self, reason):
        with self._state_lock:
            if self._state == 'closed':
                return
            self._state = 'failed'
            self._epoch = None
            self._manifest.setdefault('failure', reason)
            if self._manifest['requests'] and self._manifest['requests'][-1]['status'] == 'active':
                self._manifest['requests'][-1].update(status='failed', failure=reason)
            self._cancellation.set()
        self._retire()
        self._save()

    def cancel(self):
        self._fail('Cancellation requested; epoch permanently retired')

    def close(self):
        if not self._operation.acquire(blocking=False):
            self.cancel()
            return
        try:
            with self._state_lock:
                state = self._state
                if state == 'closed':
                    return
                if state == 'new':
                    self._epoch = None
                    self._state = 'closed'
                    return
                if state != 'idle':
                    self._retire()
                    return
                self._state = 'closing'
            deadline = time.monotonic() + min(5, self.spec['timeout_seconds'])
            self._io.require_idle()
            command = dict(version=protocol.VERSION, type='shutdown', epoch=self._epoch, sequence=self._sequence + 1)
            self._io.send(command, deadline)
            for rank in range(len(self._ranks)):
                protocol.frame(self._io.receive(rank, deadline), 'stopped', command['epoch'], rank, command['sequence'])
            for process in self._processes:
                code = process.wait(timeout=max(0.01, deadline - time.monotonic()))
                protocol.same(code, 0, 'graceful shutdown exit code')
            with self._state_lock:
                self._state = 'closed'
                self._epoch = None
            self._retire()
            self._save()
        except BaseException as error:
            self._fail(f'Shutdown failed: {error}')
            if isinstance(error, (KeyboardInterrupt, SystemExit)):
                raise
        finally:
            self._operation.release()

    def __enter__(self):
        self.start()
        return self

    def __exit__(self, kind, value, traceback):
        if kind is not None:
            self.cancel()
        else:
            self.close()
        return False
