"""Run a frozen study through an explicitly supplied, supervised cohort adapter.

This module starts no native process itself. The adapter owns artifact checks,
fresh request state, timing fences, admission, cancellation and process cleanup.
"""

from copy import deepcopy

from .aggregate import summarize, validate_measurement
from .specification import make_schedule, read_study


def _error_text(error):
    name = type(error).__name__
    try:
        detail = str(error)
    except BaseException:
        detail = 'exception message unavailable'
    text = (name + ': ' + detail).replace('\x00', '\\0')
    return text.encode('utf-8', errors='replace')[:2048].decode('utf-8', errors='ignore')


class _Execution:
    def __init__(self, study, schedule, publish):
        self.study, self.schedule, self.publish = study, schedule, publish
        self.outcomes, self.events, self.cohort_errors = [], [], []
        self.publication_failed = False

    def emit(self, event):
        self.events.append(deepcopy(event))
        if self.publish is not None and not self.publication_failed:
            try:
                self.publish(deepcopy(event))
            except BaseException:
                self.publication_failed = True
                raise

    def outcome(self, request, status, measurement=None, error=None):
        item = dict(request_id=request['request_id'], status=status,
                    measurement=deepcopy(measurement), error=error)
        self.outcomes.append(item)
        return item

    def secondary_failure(self, cohort_id, original, secondary):
        # Preserve cleanup/publication failures without hiding an operator stop.
        chosen = original if not isinstance(original, Exception) else secondary
        other = secondary if chosen is original else original
        self.cohort_errors.append(dict(cohort_id=cohort_id, error=_error_text(other)))
        raise chosen from other

    def cohort(self, cohort, open_cohort):
        self.emit(dict(event='cohort_started', cohort_id=cohort['cohort_id']))
        body_failure = None
        try:
            with open_cohort(deepcopy(self.study), deepcopy(cohort)) as runner:
                try:
                    for request in cohort['requests']:
                        self.request(cohort['cohort_id'], request, runner)
                except BaseException as error:
                    body_failure = error
                    raise
        except BaseException as error:
            if body_failure is not None and error is not body_failure:
                self.secondary_failure(cohort['cohort_id'], body_failure, error)
            raise
        # An adapter must not turn a failed request into a continuing study by
        # suppressing the exception from its context manager.
        if body_failure is not None:
            raise body_failure
        self.emit(dict(event='cohort_completed', cohort_id=cohort['cohort_id']))

    def request(self, cohort_id, request, runner):
        self.emit(dict(event='request_started', cohort_id=cohort_id, request=deepcopy(request)))
        try:
            measurement = validate_measurement(runner.run(deepcopy(request)))
        except BaseException as error:
            item = self.outcome(request, 'failed', error=_error_text(error))
            try:
                self.emit(dict(event='request_finished', outcome=item))
            except BaseException as sink_error:
                self.secondary_failure(cohort_id, error, sink_error)
            raise
        item = self.outcome(request, 'completed', measurement=measurement)
        self.emit(dict(event='request_finished', outcome=item))

    def finish(self):
        completed = {row['request_id'] for row in self.outcomes}
        for cohort in self.schedule:
            for request in cohort['requests']:
                if request['request_id'] not in completed:
                    self.outcome(request, 'skipped', error='Study stopped before this request')
        # Restore frozen schedule order after filling unattempted cells.
        by_id = {item['request_id']:item for item in self.outcomes}
        self.outcomes = [by_id[request['request_id']]
                         for cohort in self.schedule for request in cohort['requests']]
        return deepcopy(dict(
            schema='cluster_prefill_study_execution_v1', study=self.study,
            schedule=self.schedule, outcomes=self.outcomes, cohort_errors=self.cohort_errors,
            events=self.events, publication_failed=self.publication_failed,
            summary=summarize(self.study, self.schedule, self.outcomes, self.cohort_errors)))


def run_study(document, open_cohort, on_event=None):
    """Execute at most 20 four-request cohorts; stop without retry on any error.

    ``open_cohort(study, cohort)`` returns a context manager whose value provides
    ``run(request)``. Each request returns the normalized measurement accepted
    by ``validate_measurement``. All callback inputs and returned data are
    detached. An optional event sink can persist each start/result before more
    work begins. A sink failure stops the study and is reported in the result.

    Ordinary adapter errors return an incomplete result. Interrupts still unwind
    the context manager and are re-raised with ``study_result`` containing the
    partial result and all remaining cells marked skipped. The injected adapter
    must itself bound blocking calls and clean up failed context entry.
    """
    if not callable(open_cohort) or (on_event is not None and not callable(on_event)):
        raise ValueError('Cohort factory and optional event sink must be callable')
    study = read_study(document)
    schedule = make_schedule(study)
    execution = _Execution(study, schedule, on_event)
    interrupted = None
    for cohort in schedule:
        try:
            execution.cohort(cohort, open_cohort)
        except BaseException as error:
            execution.cohort_errors.append(dict(cohort_id=cohort['cohort_id'], error=_error_text(error)))
            if not execution.publication_failed:
                try:
                    execution.emit(dict(event='study_aborted', cohort_id=cohort['cohort_id'],
                                        error=_error_text(error)))
                except BaseException as sink_error:
                    execution.cohort_errors.append(dict(cohort_id=cohort['cohort_id'],
                                                        error=_error_text(sink_error)))
                    if not isinstance(sink_error, Exception):
                        interrupted = sink_error
            if not isinstance(error, Exception):
                interrupted = error
            break
    result = execution.finish()
    if interrupted is not None:
        interrupted.study_result = result
        raise interrupted
    return result
