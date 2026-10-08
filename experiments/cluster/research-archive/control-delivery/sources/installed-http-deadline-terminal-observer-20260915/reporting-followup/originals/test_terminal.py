"""Fabricated terminal DTOs and local fake HTTP; no native or real peer access."""

import copy
import json
from pathlib import Path
import tempfile
import unittest

from client import run
from terminal_observation import TerminalObservation, terminal_error
from test_client import server, event, DONE, USAGE, SECRET, MODEL
from harness.terminal_contract import validate_client, natural_failure_exit


def failure(code='deadline_unreachable', cause=None):
    value = dict(error=dict(type='server_error', code=code,
                 message='First visible content deadline was not met' if code == 'deadline_unreachable'
                 else 'Distributed generation did not complete'),
                 attempt_usage=dict(prompt_tokens=8192, completion_tokens=0))
    if cause is not None: value['error']['terminal_cause'] = cause
    return value


def frame(value):
    return ('data: ' + json.dumps(value) + '\n\n').encode()


def complete_receipt():
    observation = TerminalObservation(MODEL)
    observation.accept(json.dumps(failure()), 18_300_000_000)
    observation.accept('[DONE]', 18_310_000_000)
    return dict(schema='installed_external_terminal_observer_v1', status='failed',
                http_status=200, error=dict(type='ClientOutcome', code='typed_terminal_failure'),
                capture_complete=True, http_body_eof_observed=True,
                http_body_eof_received_ns=18_320_000_000,
                cleanup_clock='clock_gettime(CLOCK_MONOTONIC)',
                connection_close_system_monotonic_ns=100_000_000_000,
                measurement=observation.content_summary(18_320_000_000, 8192, False))


class TerminalTests(unittest.TestCase):
    def request(self, chunks, timeout=2):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root/'prompt').write_text('Fabricated model-free prompt.')
            (root/'token').write_text(SECRET); (root/'token').chmod(0o600)
            with server(chunks) as (endpoint, _):
                result = run(endpoint, MODEL, root/'prompt', root/'token', root/'out', timeout, 8192)
            raw = (root/'out/response.sse').read_bytes()
            return result, raw

    def test_closed_typed_error_and_attempt_usage(self):
        for value in (failure(), failure('inference_error', 'prefill_stall'), failure('inference_error')):
            error, usage = terminal_error(value)
            self.assertEqual(error, value['error'])
            self.assertEqual(usage, dict(prompt_tokens=8192, completion_tokens=0))

    def test_malformed_false_usage_and_unknown_fields_refuse(self):
        mutations = [lambda v: v.update(extra=True), lambda v: v.pop('attempt_usage'),
                     lambda v: v['attempt_usage'].update(completion_tokens=False),
                     lambda v: v['attempt_usage'].update(prompt_tokens=8192.0),
                     lambda v: v['attempt_usage'].update(prompt_tokens=8193),
                     lambda v: v['attempt_usage'].update(completion_tokens=129),
                     lambda v: v['attempt_usage'].update(total_tokens=8192),
                     lambda v: v['error'].update(code='unknown'),
                     lambda v: v['error'].update(type='other'),
                     lambda v: v['error'].update(terminal_cause='prefill_stall'),
                     lambda v: v['error'].update(message='arbitrary'),
                     lambda v: v['error'].update(message='x'*5000)]
        for mutation in mutations:
            value = failure(); mutation(value)
            with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                TerminalObservation(MODEL).accept(json.dumps(value), 1)
        for cause in ('unknown', None, [], False):
            value = failure('inference_error'); value['error']['terminal_cause'] = cause
            with self.subTest(cause=cause), self.assertRaises(ValueError): terminal_error(value)
        with self.assertRaises(ValueError):
            TerminalObservation(MODEL).accept('{"error":{},"error":{}}', 1)

    def test_terminal_order_duplicate_and_missing_done(self):
        value = json.dumps(failure())
        for suffix in (value, json.dumps(dict(choices=[])), '[DONE]'):
            observation = TerminalObservation(MODEL); observation.accept(value, 1)
            if suffix == '[DONE]': observation.accept(suffix, 2)
            with self.subTest(suffix=suffix), self.assertRaises(ValueError): observation.accept(suffix, 3)
        observation = TerminalObservation(MODEL); observation.accept(value, 1)
        self.assertFalse(observation.content_summary(2, 8192, False)['failure_terminal_complete'])

    def test_normal_finish_then_error_refuses(self):
        observation = TerminalObservation(MODEL)
        observation.accept(event(finish='length', usage=USAGE).decode().split('data: ', 1)[1].strip(), 1)
        with self.assertRaises(ValueError): observation.accept(json.dumps(failure()), 2)

    def test_error_never_becomes_success_even_after_content(self):
        observation = TerminalObservation(MODEL)
        observation.accept(event(content='visible').decode().split('data: ', 1)[1].strip(), 1)
        observation.accept(json.dumps(failure('inference_error', 'decode_stall')), 20_000_000_000)
        observation.accept('[DONE]', 20_000_000_001)
        summary = observation.content_summary(30_000_000_000, 8192, True)
        self.assertTrue(summary['failure_terminal_complete'])
        self.assertTrue(all(not row['request_passed'] for row in summary['content_sla'].values()))
        self.assertEqual(summary['content_sla']['attempt_reported_prompt_tokens']['deadline_ns'], 18_192_000_000)

    def test_actual_fake_http_reads_error_then_done_then_eof(self):
        chunks = [(0, event()), (0, b': keep-alive\n\n'),
                  (0, frame(failure('inference_error', 'prefill_stall'))), (.025, DONE)]
        result, raw = self.request(chunks)
        self.assertEqual(raw, b''.join(data for _, data in chunks))
        self.assertEqual(result['status'], 'failed')
        self.assertEqual(result['error']['code'], 'typed_terminal_failure')
        self.assertTrue(result['capture_complete']); self.assertTrue(result['http_body_eof_observed'])
        self.assertTrue(result['measurement']['failure_terminal_complete'])
        self.assertGreater(result['http_body_eof_received_ns'], result['measurement']['typed_error_received_ns'])
        self.assertIsNone(result['measurement']['usage'])
        self.assertEqual(result['measurement']['attempt_usage'], dict(prompt_tokens=8192, completion_tokens=0))
        self.assertFalse(result['native_retirement_verified'])

    def test_actual_fake_http_error_eof_without_done_refuses(self):
        result, _ = self.request([(0, frame(failure()))])
        self.assertEqual(result['error']['code'], 'typed_error_missing_done')
        self.assertTrue(result['http_body_eof_observed'])
        self.assertFalse(result['measurement']['failure_terminal_complete'])

    def test_actual_fake_http_role_only_is_not_terminal(self):
        result, _ = self.request([(0, event()), (0, b': keep-alive\n\n')])
        self.assertEqual(result['status'], 'failed')
        self.assertEqual(result['error']['code'], 'incomplete_stream')
        self.assertIsNone(result['measurement']['first_content_ns'])
        self.assertIsNone(result['measurement']['typed_error'])

    def test_actual_fake_http_missing_eof_obeys_absolute_bound(self):
        result, _ = self.request([(0, frame(failure())), (0, DONE)]
                                 + [(.025, b': keep-alive\n\n')] * 20, timeout=.15)
        self.assertEqual(result['error']['code'], 'absolute_timeout')
        self.assertFalse(result['http_body_eof_observed'])
        self.assertFalse(result['capture_complete'])
        self.assertTrue(result['measurement']['failure_terminal_complete'])
        self.assertFalse(result['measurement']['content_sla']['declared_prompt_tokens']['request_passed'])

    def test_harness_qualifies_observation_without_success(self):
        result = validate_client(complete_receipt(), 1)
        self.assertTrue(result['typedDeadlineFailureObserved'])
        self.assertTrue(result['errorReceivedAfterContentCutoff'])
        self.assertFalse(result['inferenceRequestSucceeded']); self.assertFalse(result['slaPassed'])
        early = complete_receipt(); early['measurement']['typed_error_received_ns'] = 1
        self.assertFalse(validate_client(early, 1)['errorReceivedAfterContentCutoff'])

    def test_harness_rejects_missing_terminal_false_usage_success_and_late_text(self):
        mutations = [lambda v: v.update(status='completed'), lambda v: v.update(http_body_eof_observed=False),
                     lambda v: v['measurement'].update(failure_terminal_complete=False),
                     lambda v: v['measurement']['attempt_usage'].update(completion_tokens=False),
                     lambda v: v['measurement']['attempt_usage'].update(prompt_tokens=23),
                     lambda v: v['measurement'].update(first_content_ns=20_000_000_000),
                     lambda v: v['measurement']['typed_error'].update(code='inference_error', terminal_cause='engine_error'),
                     lambda v: v['measurement']['content_sla']['declared_prompt_tokens'].update(request_passed=True),
                     lambda v: v.update(cleanup_clock='process-relative-monotonic')]
        for mutation in mutations:
            value = complete_receipt(); mutation(value)
            with self.subTest(mutation=mutation), self.assertRaises(ValueError): validate_client(value, 1)
        with self.assertRaises(ValueError): validate_client(complete_receipt(), 0)

    def test_natural_runtime_exit1_only(self):
        value = dict(state='exited', stopReason='natural-exit', forcedKill=False, exitCode=1)
        self.assertTrue(natural_failure_exit([value], 1))
        for change in ({'exitCode': 0}, {'exitCode': True}, {'forcedKill': True}, {'stopReason': 'requested-stop'}):
            other = dict(value); other.update(change)
            self.assertFalse(natural_failure_exit([other], 1))
        self.assertFalse(natural_failure_exit([value], 0))
        self.assertFalse(natural_failure_exit([value], True))
        self.assertFalse(natural_failure_exit([], 1))


if __name__ == '__main__': unittest.main()
