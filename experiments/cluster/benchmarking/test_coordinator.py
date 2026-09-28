"""Injected CPU runners exercise scheduling, cleanup and incomplete studies."""

from copy import deepcopy
import unittest
from unittest.mock import patch

from .coordinator import run_study
from .test_specification import study_document


class Factory:
    def __init__(self, fail_at=None, invalid=False, enter_error=None,
                 close_at=None, suppress=False, interrupt=False, mutate=False):
        self.opened, self.closed, self.requests = [], [], []
        self.fail_at, self.invalid, self.enter_error = fail_at, invalid, enter_error
        self.close_at, self.suppress = close_at, suppress
        self.interrupt, self.mutate = interrupt, mutate
        self.active = False
        self.last_measurement = None

    def __call__(self, study, cohort):
        assert not self.active, 'Cohorts must never overlap'
        self.cohort = deepcopy(cohort)
        self.opened.append(cohort['cohort_id'])
        if self.mutate:
            study['prompts'].clear(); cohort['requests'].clear()
        return self

    def __enter__(self):
        if self.enter_error:
            raise self.enter_error
        self.active = True
        return self

    def __exit__(self, kind, value, traceback):
        self.active = False
        self.closed.append(self.cohort['cohort_id'])
        if len(self.closed) == self.close_at:
            raise RuntimeError('fabricated close failure')
        return self.suppress

    def run(self, request):
        assert self.active
        self.requests.append(deepcopy(request))
        if len(self.requests) == self.fail_at:
            if self.interrupt:
                raise KeyboardInterrupt('fabricated operator interruption')
            if self.invalid:
                return dict(elapsed_ns=True, prompt_tokens=8192,
                            generated_tokens=1, source_sha256='f'*64)
            raise RuntimeError('fabricated request failure')
        duration = 10**15 if request['phase'] == 'warmup' else 8_000_000_000
        self.last_measurement = dict(elapsed_ns=duration, prompt_tokens=8192,
                                     generated_tokens=1, source_sha256='f'*64)
        if self.mutate:
            request.clear()
        return self.last_measurement


class CoordinatorTests(unittest.TestCase):
    def setUp(self):
        # An implementation that accidentally starts native/network work must
        # fail even when the supplied adapter is entirely fabricated.
        for target in ('subprocess.Popen', 'socket.socket'):
            block = patch(target, side_effect=AssertionError('No native/network work'))
            block.start(); self.addCleanup(block.stop)

    def test_complete_schedule_is_sequential_and_excludes_warmups(self):
        source = study_document(); original = deepcopy(source)
        factory = Factory(); events = []
        result = run_study(source, factory, events.append)
        self.assertEqual(source, original)
        self.assertEqual(len(factory.opened), 20)
        self.assertEqual(factory.closed, factory.opened)
        self.assertEqual(len(factory.requests), 80)
        self.assertEqual(result['summary']['aggregate_status'], 'complete')
        self.assertEqual(result['events'], events)
        self.assertEqual(sum(row['status']=='completed' for row in result['outcomes']), 80)
        self.assertFalse(result['publication_failed'])
        self.assertFalse(factory.active)

    def test_request_failure_retains_failed_and_skipped_cells_without_retry(self):
        for invalid in (False, True):
            with self.subTest(invalid=invalid):
                factory = Factory(fail_at=3, invalid=invalid)
                result = run_study(study_document(), factory)
                self.assertEqual(len(factory.opened), 1)
                self.assertEqual(len(factory.closed), 1)
                self.assertEqual(len(factory.requests), 3)
                self.assertEqual([row['status'] for row in result['outcomes'][:4]],
                                 ['completed', 'completed', 'failed', 'skipped'])
                self.assertEqual(sum(row['status']=='skipped' for row in result['outcomes']), 77)
                self.assertEqual(result['summary']['aggregate_status'], 'incomplete')

    def test_failed_warmup_prevents_all_measured_work(self):
        factory = Factory(fail_at=1)
        result = run_study(study_document(), factory)
        self.assertEqual(len(factory.requests), 1)
        self.assertEqual(result['outcomes'][0]['status'], 'failed')
        self.assertEqual(sum(row['status']=='skipped' for row in result['outcomes']), 79)

    def test_adapter_cannot_suppress_request_or_publication_failure(self):
        factory = Factory(fail_at=2, suppress=True)
        result = run_study(study_document(), factory)
        self.assertEqual(len(factory.opened), 1)
        self.assertEqual(result['summary']['aggregate_status'], 'incomplete')
        factory = Factory(suppress=True)
        def broken(event):
            if event['event'] == 'request_started':
                raise OSError('fabricated journal failure')
        result = run_study(study_document(), factory, broken)
        self.assertTrue(result['publication_failed'])
        self.assertEqual(len(factory.opened), 1)
        self.assertEqual(len(factory.requests), 0)
        self.assertEqual(len(factory.closed), 1)

    def test_failed_entry_and_close_preserve_incomplete_result(self):
        factory = Factory(enter_error=RuntimeError('fabricated entry failure'))
        result = run_study(study_document(), factory)
        self.assertEqual(len(factory.requests), 0)
        self.assertEqual(len(result['outcomes']), 80)
        self.assertEqual(result['summary']['aggregate_status'], 'incomplete')
        # A final close failure invalidates even a study with all 80 results.
        factory = Factory(close_at=20)
        result = run_study(study_document(), factory)
        self.assertEqual(len(factory.requests), 80)
        self.assertEqual(len(factory.closed), 20)
        self.assertEqual(result['summary']['aggregate_status'], 'incomplete')
        self.assertTrue(result['cohort_errors'])

    def test_journal_failure_stops_before_any_new_native_adapter_work(self):
        for fail_event, requests in (('cohort_started', 0), ('request_started', 0),
                                     ('request_finished', 1), ('cohort_completed', 4)):
            with self.subTest(event=fail_event):
                calls = []
                def broken(event):
                    calls.append(event)
                    if event['event'] == fail_event:
                        raise OSError('fabricated publication failure')
                factory = Factory()
                result = run_study(study_document(), factory, broken)
                self.assertEqual(len(factory.requests), requests)
                self.assertLessEqual(len(factory.opened), 1)
                self.assertFalse(factory.active)
                self.assertTrue(result['publication_failed'])
                self.assertEqual(result['summary']['aggregate_status'], 'incomplete')
                self.assertEqual(calls[-1]['event'], fail_event)

    def test_interrupt_retires_cohort_and_carries_partial_result(self):
        for close_at in (None, 1):
            with self.subTest(close_at=close_at):
                factory = Factory(fail_at=2, interrupt=True, close_at=close_at)
                with self.assertRaises(KeyboardInterrupt) as caught:
                    run_study(study_document(), factory)
                result = caught.exception.study_result
                self.assertEqual(len(factory.requests), 2)
                self.assertEqual(len(factory.closed), 1)
                self.assertFalse(factory.active)
                self.assertEqual(result['outcomes'][1]['status'], 'failed')
                self.assertEqual(result['summary']['aggregate_status'], 'incomplete')
                if close_at:
                    self.assertTrue(any('close failure' in row['error'] for row in result['cohort_errors']))

    def test_simultaneous_request_publication_and_close_failures_are_retained(self):
        factory = Factory(fail_at=1, close_at=1)
        def broken(event):
            if event['event'] == 'request_finished':
                raise OSError('fabricated failed-result publication')
        result = run_study(study_document(), factory, broken)
        self.assertEqual(result['outcomes'][0]['status'], 'failed')
        errors = '\n'.join(row['error'] for row in result['cohort_errors'])
        self.assertIn('request failure', errors)
        self.assertIn('publication', errors)
        self.assertIn('close failure', errors)
        self.assertEqual(len(factory.requests), 1)

    def test_callback_mutations_cannot_change_schedule_or_returned_measurements(self):
        factory = Factory(mutate=True)
        def mutate(event):
            event.clear()
        result = run_study(study_document(), factory, mutate)
        self.assertEqual(len(factory.requests), 80)
        factory.last_measurement['elapsed_ns'] = 1
        self.assertEqual(result['outcomes'][-1]['measurement']['elapsed_ns'], 8_000_000_000)
        self.assertEqual(len(result['study']['prompts']), 10)
        self.assertEqual(len(result['schedule'][0]['requests']), 4)
        self.assertTrue(all(event for event in result['events']))

    def test_invalid_input_refuses_before_factory_or_sink(self):
        factory = Factory(); events = []
        value = study_document(); value['seed'] = True
        with self.assertRaises(ValueError): run_study(value, factory, events.append)
        self.assertEqual(factory.opened, [])
        self.assertEqual(events, [])
        with self.assertRaises(ValueError): run_study(study_document(), None)

    def test_error_text_is_bounded_utf8_and_has_no_nul(self):
        factory = Factory(enter_error=RuntimeError(('🔥\0')*4096))
        result = run_study(study_document(), factory)
        error = result['cohort_errors'][0]['error']
        self.assertLessEqual(len(error.encode()), 2048)
        self.assertNotIn('\0', error)

    def test_unprintable_adapter_errors_still_retain_results_and_cleanup(self):
        class Unprintable(Exception):
            def __str__(self):
                raise RuntimeError('fabricated formatting failure')
        class BrokenRunner(Factory):
            def run(self, request):
                self.requests.append(deepcopy(request))
                raise Unprintable()
        for factory in (Factory(enter_error=Unprintable()), BrokenRunner()):
            result = run_study(study_document(), factory)
            self.assertEqual(result['summary']['aggregate_status'], 'incomplete')
            self.assertEqual(len(result['outcomes']), 80)
            self.assertIn('Unprintable', result['cohort_errors'][0]['error'])
            self.assertFalse(factory.active)
            if factory.requests:
                self.assertEqual(len(factory.closed), 1)
                self.assertEqual(result['outcomes'][0]['status'], 'failed')


if __name__ == '__main__':
    unittest.main()
