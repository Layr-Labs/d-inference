"""Observe the current distributed error DTO without accepting failed inference."""

from client_observation import ContentObservation
from streaming_latency import strict_json

CAUSES = frozenset(('admission_timeout', 'prefill_stall', 'decode_stall',
                   'safety_deadline', 'backpressure_timeout', 'watchdog',
                   'cancelled', 'engine_error'))


def terminal_error(event):
    if type(event) is not dict or set(event) != {'error', 'attempt_usage'}:
        raise ValueError('Invalid terminal error fields')
    error, usage = event['error'], event['attempt_usage']
    if (type(error) is not dict
            or set(error) not in ({'type', 'code', 'message'},
                                  {'type', 'code', 'message', 'terminal_cause'})
            or error['type'] != 'server_error'):
        raise ValueError('Invalid typed terminal error')
    if error['code'] == 'deadline_unreachable':
        if ('terminal_cause' in error
                or error['message'] != 'First visible content deadline was not met'):
            raise ValueError('Invalid visible-content deadline error')
    elif error['code'] == 'inference_error':
        if (error['message'] != 'Distributed generation did not complete'
                or ('terminal_cause' in error and (type(error['terminal_cause']) is not str or error['terminal_cause'] not in CAUSES))):
            raise ValueError('Invalid inference terminal cause')
    else:
        raise ValueError('Unknown terminal error code')
    if (type(usage) is not dict or set(usage) != {'prompt_tokens', 'completion_tokens'}
            or type(usage['prompt_tokens']) is not int or not 0 <= usage['prompt_tokens'] <= 8192
            or type(usage['completion_tokens']) is not int or not 0 <= usage['completion_tokens'] <= 128):
        raise ValueError('Invalid reported attempt usage')
    return dict(error), dict(usage)


class TerminalObservation(ContentObservation):
    def __init__(self, model):
        super().__init__(model)
        self.typed_error = self.attempt_usage = self.typed_error_received_ns = None

    def accept(self, payload, elapsed_ns):
        if self.done:
            raise ValueError('Data after DONE')
        if self.typed_error is not None:
            if payload != '[DONE]':
                raise ValueError('Data after typed terminal error')
            return super().accept(payload, elapsed_ns)
        if payload != '[DONE]':
            event = strict_json(payload)
            if type(event) is dict and 'error' in event:
                if self.finish_reason is not None or self.usage is not None:
                    raise ValueError('Error after normal terminal')
                if len(payload.encode()) + len('data: \n\ndata: [DONE]\n\n') > 4096:
                    raise ValueError('Terminal frame exceeded native bound')
                error, usage = terminal_error(event)
                self.typed_error, self.attempt_usage = error, usage
                self.typed_error_received_ns = elapsed_ns
                self.event_count += 1
                return
        super().accept(payload, elapsed_ns)

    def content_summary(self, elapsed_ns, declared, succeeded):
        summary = super().content_summary(elapsed_ns, declared,
                                          succeeded and self.typed_error is None)
        summary.update(typed_error=self.typed_error, attempt_usage=self.attempt_usage,
                       typed_error_received_ns=self.typed_error_received_ns,
                       failure_terminal_complete=self.typed_error is not None and self.done,
                       attempt_usage_independently_verified=False)
        if self.attempt_usage is not None:
            deadline = 10_000_000_000 + self.attempt_usage['prompt_tokens'] * 1_000_000
            margin = None if self.first_content_ns is None else deadline - self.first_content_ns
            summary['content_sla']['attempt_reported_prompt_tokens'] = dict(
                deadline_ns=deadline, content_margin_ns=margin,
                content_received_in_time=None if margin is None else margin >= 0,
                request_passed=False)
        return summary
