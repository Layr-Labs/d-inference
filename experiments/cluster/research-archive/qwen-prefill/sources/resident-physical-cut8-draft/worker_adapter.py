"""Explicit callback-bound cohort interface; no built-in numerical qualification."""

from worker_contract import WorkerSpec, detached, event, open_command, require, run_command, workers as validate_workers
from worker_processes import PipeWorkers


class ResidentWorkerCohort:
    def __init__(self, workers, cohort_id, requests, output_directory, timeout_seconds,
                 resource_gate, identity_validator, numerical_validator):
        # Required callback presence is checked before creating files/processes.
        for callback in (resource_gate, identity_validator, numerical_validator):
            require(callable(callback), 'Explicit resource/identity/numerical callbacks are required')
        self._specs = validate_workers(workers)
        self._opened = open_command(cohort_id, requests)
        self._identity, self._numerical = identity_validator, numerical_validator
        self._pipes = PipeWorkers(self._specs, output_directory, timeout_seconds, resource_gate)
        self._ordinal = 0
        self._entered = self._active = self._released = self._stopped = self._failed = False
        self._ready_to_run = False
        self._identity_calls = self._numerical_calls = 0
        self._ready, self._results = [], []

    def _spec(self, index):
        spec = self._specs[index]
        return WorkerSpec(tuple(spec.argv), dict(spec.env), spec.role, spec.rank)

    def _validated_events(self, kind, command):
        def validate(index, raw):
            value = event(raw, self._specs[index], kind, command)
            self._pipes.check()
            self._identity_calls += 1
            require(self._identity(self._spec(index), detached(value), detached(command)) is None,
                    'Identity validator must return None on success or raise')
            self._pipes.check()
            return value
        return self._pipes.collect(kind + '-wait', validate)

    def _abort(self, primary):
        self._failed = True
        try:
            self._pipes.close(kill=True)
        except BaseException as cleanup_interrupt:
            if isinstance(primary, Exception):
                raise cleanup_interrupt from primary
            # Preserve the original operator interruption after cleanup tried
            # every group/handle; the secondary remains in cleanup_errors.
        if self._pipes.cleanup_errors:
            try:
                primary.worker_cleanup_errors = tuple(self._pipes.cleanup_errors)
            except Exception:
                pass

    def __enter__(self):
        try:
            require(not self._entered and not self._failed and not self._pipes.closed, 'Cohort cannot be reentered')
            self._entered = True
            self._pipes.gate('prelaunch')
            self._pipes.start()
            self._pipes.send(self._opened)
            self._ready = self._validated_events('ready', self._opened)
            self._ready_to_run = True
            return self
        except BaseException as error:
            self._abort(error)
            raise

    def run(self, request):
        try:
            require(self._entered and self._ready_to_run and not self._failed and not self._stopped and not self._active,
                    'Cohort unavailable or request already active')
            command = run_command(self._opened, self._ordinal, request)
            self._active = True
            self._pipes.gate('before-request-%d' % self._ordinal)
            self._pipes.send(command)
            results = self._validated_events('result', command)
            self._pipes.check()
            self._numerical_calls += 1
            value = self._numerical(detached(command), detached(results))
            self._pipes.check()
            require(type(value) is dict, 'Numerical callback must return explicit CPU measurement metadata')
            measurement = detached(value)
            if self._ordinal == 3:
                self._validated_events('released', command)
                self._released = True
            self._results.append(results)
            self._ordinal += 1
            self._active = False
            return measurement
        except BaseException as error:
            self._abort(error)
            raise

    def close(self):
        if self._stopped:
            return
        try:
            require(self._entered and not self._failed and not self._active
                    and self._ordinal == 4 and self._released, 'Clean close requires four validated retired results and release')
            command = dict(schema=self._opened['schema'], type='shutdown',
                           cohort_id=self._opened['cohort_id'], sequence=5)
            self._pipes.send(command)
            self._validated_events('stopped', command)
            self._pipes.finish()
            self._stopped = True
        except BaseException as error:
            self._abort(error)
            raise

    def __exit__(self, exception_type, exception, traceback):
        if exception is not None:
            self._abort(exception)
            return False
        self.close()
        return False

    def evidence(self):
        """Transport metadata only; external callbacks do not mint qualification."""
        return dict(cohort_id=self._opened['cohort_id'], completed_requests=self._ordinal,
                    released_event_validated=self._released, stopped=self._stopped, failed=self._failed,
                    output_complete=self._pipes.complete_output, cleanup_errors=list(self._pipes.cleanup_errors),
                    workers=[dict(pid=p.pid, returncode=p.poll()) for p in self._pipes.children],
                    streams=self._pipes.retained_streams(),
                    identity_validation_callback_used=self._identity_calls > 0,
                    numerical_validation_callback_used=self._numerical_calls > 0,
                    identity_callback_calls=self._identity_calls, numerical_callback_calls=self._numerical_calls,
                    numerical_correctness_independently_established=False,
                    resource_admission_independently_established=False,
                    performance_qualification=False, runtime_admission=False)
