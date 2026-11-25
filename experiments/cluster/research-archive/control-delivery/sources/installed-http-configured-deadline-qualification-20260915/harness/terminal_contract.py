"""A delivered configured-deadline failure is an observation, never successful inference."""

DEADLINE_NS = 18_192_000_000
CONFIGURED_DEADLINE_NS = 2_000_000_000


def request_disposition(receipt):
    # An unexpected normal response is not this expected-failure observation,
    # but must not be relabeled failed inference by the harness.
    status = receipt.get('status')
    return dict(inferenceRequestSucceeded=status in ('completed', 'content_deadline_missed'),
                slaPassed=status == 'completed')


def validate_client(receipt, exit_code):
    measurement = receipt.get('measurement', {})
    error = measurement.get('typed_error')
    usage = measurement.get('attempt_usage')
    if (type(exit_code) is not int or exit_code != 1 or receipt.get('schema') != 'installed_external_terminal_observer_v1'
            or receipt.get('status') != 'failed' or receipt.get('http_status') != 200
            or receipt.get('error') != {'type': 'ClientOutcome', 'code': 'typed_terminal_failure'}
            or receipt.get('capture_complete') is not True
            or receipt.get('http_body_eof_observed') is not True
            or measurement.get('failure_terminal_complete') is not True
            or measurement.get('done') is not True
            or measurement.get('first_content_ns') is not None
            or measurement.get('declared_prompt_tokens') != 8192
            or usage != {'prompt_tokens': 8192, 'completion_tokens': 0}
            or any(type(value) is not int for value in usage.values())
            or type(error) is not dict
            or not (error.get('code') == 'deadline_unreachable'
                    or (error.get('code') == 'inference_error' and error.get('terminal_cause') == 'safety_deadline'))):
        raise ValueError('Expected complete typed configured2s failure with reported 8192/0 usage')
    sla = measurement.get('content_sla', {})
    if (set(sla) != {'attempt_reported_prompt_tokens', 'declared_prompt_tokens'}
            or any(row.get('deadline_ns') != DEADLINE_NS or row.get('request_passed') is not False
                   or row.get('content_received_in_time') is not None for row in sla.values())):
        raise ValueError('Failed content SLA must remain explicit and unchanged')
    error_time, eof_time = measurement.get('typed_error_received_ns'), receipt.get('http_body_eof_received_ns')
    closed = receipt.get('connection_close_system_monotonic_ns')
    if (type(error_time) is not int or type(eof_time) is not int or not 0 <= error_time <= eof_time
            or receipt.get('cleanup_clock') != 'clock_gettime(CLOCK_MONOTONIC)'
            or type(closed) is not int or closed < 0 or receipt.get('cleanup_errors')):
        raise ValueError('Missing bounded EOF/close observation')
    return dict(typedDeadlineFailureObserved=True, responseEOFObserved=True,
                typedError=error, reportedAttemptUsage=usage,
                errorReceivedAfterContentCutoff=error_time >= DEADLINE_NS,
                configuredRequestDeadlineNanoseconds=CONFIGURED_DEADLINE_NS,
                errorReceivedAfterConfiguredCutoff=error_time >= CONFIGURED_DEADLINE_NS,
                naturalContentDeadlineMissReproduced=False,
                inferenceRequestSucceeded=False, slaPassed=False,
                closeOrigin=closed / 1e9)


def natural_failure_exit(finals, supervisor_exit):
    return (len(finals) == 1 and finals[0].get('state') == 'exited'
            and finals[0].get('stopReason') == 'natural-exit'
            and finals[0].get('forcedKill') is False
            and type(finals[0].get('exitCode')) is int and finals[0]['exitCode'] == 1
            and type(supervisor_exit) is int and supervisor_exit == 1)


def observation_qualified(record):
    terminal = record.get('terminalObservation', {})
    cleanup = record.get('selfRetirement', {})
    monitors = record.get('monitors', [])
    return (type(record.get('configuredRequestTimeoutSeconds')) is int
            and record['configuredRequestTimeoutSeconds'] == 2
            and terminal.get('typedDeadlineFailureObserved') is True
            and terminal.get('configuredRequestDeadlineNanoseconds') == CONFIGURED_DEADLINE_NS
            and terminal.get('errorReceivedAfterConfiguredCutoff') is True
            and terminal.get('inferenceRequestSucceeded') is False and terminal.get('slaPassed') is False
            and record.get('statusBefore', {}).get('validated') is True
            and cleanup.get('self_retirement_observed') is True
            and cleanup.get('harness_interference_observed') is False
            and record.get('supervisorNaturalFailureExitObserved') is True
            and record.get('nativeProcessesAbsent') is True and record.get('journalsEmpty') is True
            and record.get('aliasCleanup', {}).get('restored') is True
            and not record.get('guardErrors')
            and len(monitors) == 2 and all(m.get('exitCode') == 0 and not m.get('errors') for m in monitors)
            and record.get('pinsUnchanged') is True and 'error' not in record)
