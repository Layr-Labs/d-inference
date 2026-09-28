"""Adversarial persistent-cohort tests with real CPU subprocess ownership.

These establish protocol/lifecycle behavior, not inference correctness or speed.
The fake worker uses no model, Metal, remote connection, or provider service.
"""

import os
import signal
import threading
import time
import unittest

from persistent_test_support import PersistentFixture, cohort_spec, process_running, wait_until
from runtime.persistent import PersistentCohort, PersistentCohortError


class PersistentLifecycleTests(unittest.TestCase):
    def fixture(self, actions=None, start=True):
        fixture = PersistentFixture(actions)
        self.addCleanup(fixture.cleanup)
        cohort = PersistentCohort(cohort_spec(), fixture.source, fixture.output)
        self.addCleanup(cohort.close)
        if start:
            ready = cohort.start()
            self.assertEqual(len(ready), 2)
            self.assertEqual(cohort.state, 'idle')
            self.assertEqual(len(cohort.epoch), 32)
            self.assertTrue(all(process_running(pid) for pid in fixture.process_ids()))
        return fixture, cohort

    def request(self, cohort, request_id='request-1', **kwargs):
        return cohort.infer(request_id, [3, 9, 14, 18], 3, 3, **kwargs)

    def assert_fenced(self, fixture, cohort):
        self.assertIsNone(cohort.epoch)
        self.assertIn(cohort.state, ('failed', 'closed'))
        # This check runs before close() or the fixture's emergency SIGKILL.
        fixture.assert_stopped()
        before = [[event for event in fixture.events(rank) if event['event'] == 'infer']
                  for rank in (0, 1)]
        with self.assertRaises(RuntimeError):
            self.request(cohort, 'must-never-be-dispatched')
        with self.assertRaises(RuntimeError):
            cohort.start()
        after = [[event for event in fixture.events(rank) if event['event'] == 'infer']
                 for rank in (0, 1)]
        self.assertEqual(before, after, 'A fenced epoch dispatched new work')

    def run_in_thread(self, cohort, request_id='active', **kwargs):
        outcome = []

        def execute():
            try:
                outcome.append(('result', self.request(cohort, request_id, **kwargs)))
            except BaseException as error:
                outcome.append(('error', error))

        thread = threading.Thread(target=execute, daemon=True)
        thread.start()
        self.addCleanup(thread.join, 4)
        return thread, outcome

    def test_three_requests_reuse_loaded_workers_and_a_repeat_has_no_b_state(self):
        fixture, cohort = self.fixture()
        epoch = cohort.epoch
        loaded = [[event for event in fixture.events(rank) if event['event'] == 'loaded']
                  for rank in (0, 1)]
        delivered = []
        first = self.request(cohort, 'A-1', capture_logits=True,
                             on_token=lambda step, token: delivered.append((step, token)))
        other = cohort.infer('B', [20, 21, 22], 3, 2, teacher_tokens=[17, 18])
        repeated = self.request(cohort, 'A-2', capture_logits=True)
        self.assertEqual(cohort.epoch, epoch)
        self.assertEqual(cohort.state, 'idle')
        for rank in (0, 1):
            self.assertEqual(first[rank]['result']['generatedTokens'],
                             repeated[rank]['result']['generatedTokens'])
            self.assertEqual(first[rank]['logits'], repeated[rank]['logits'])
            self.assertNotEqual(first[rank]['result']['generatedTokens'],
                                other[rank]['result']['generatedTokens'])
            self.assertEqual(other[rank]['result']['decodeInputTokens'], [17, 18])
            self.assertEqual([record[rank]['result']['iteration'] for record in (first, other, repeated)],
                             [1, 2, 3])
            self.assertEqual([record[rank]['modelLoadID'] for record in (first, other, repeated)],
                             [loaded[rank][0]['model_load_id']] * 3)
            self.assertEqual([event for event in fixture.events(rank) if event['event'] == 'loaded'],
                             loaded[rank])
            self.assertEqual([event['request_id'] for event in fixture.events(rank)
                              if event['event'] == 'infer'], ['A-1', 'B', 'A-2'])
        self.assertEqual(delivered, list(enumerate(first[0]['result']['generatedTokens'])))
        cohort.close()
        fixture.assert_stopped()
        self.assert_fenced(fixture, cohort)

    def test_one_peer_wrong_token_never_delivers_the_disputed_step(self):
        fixture, cohort = self.fixture({'1': 'wrong_token'})
        delivered = []
        with self.assertRaises(PersistentCohortError):
            self.request(cohort, on_token=lambda step, token: delivered.append((step, token)))
        self.assertEqual([step for step, _ in delivered], [0])
        self.assert_fenced(fixture, cohort)

    def test_peer_request_hash_and_load_mismatches_fence_before_tokens(self):
        for fault in ('wrong_request', 'wrong_hash', 'wrong_load', 'wrong_epoch', 'wrong_sequence'):
            with self.subTest(fault=fault):
                fixture, cohort = self.fixture({'1': fault})
                delivered = []
                with self.assertRaises(PersistentCohortError):
                    self.request(cohort, on_token=lambda *token: delivered.append(token))
                self.assertEqual(delivered, [])
                self.assert_fenced(fixture, cohort)

    def test_token_and_completion_cannot_claim_another_request_or_load(self):
        for fault in ('wrong_token_request', 'wrong_completed_request', 'wrong_completed_load'):
            with self.subTest(fault=fault):
                fixture, cohort = self.fixture({'1': fault})
                with self.assertRaises(PersistentCohortError):
                    self.request(cohort)
                self.assert_fenced(fixture, cohort)

    def test_native_eof_with_live_process_kills_both_workers_and_descendants(self):
        fixture, cohort = self.fixture({'1': 'eof'})
        with self.assertRaises(PersistentCohortError):
            self.request(cohort, timeout_seconds=2)
        self.assert_fenced(fixture, cohort)

    def test_crashed_native_leader_does_not_leave_its_descendant_or_peer(self):
        fixture, cohort = self.fixture({'1': 'crash'})
        with self.assertRaises(PersistentCohortError):
            self.request(cohort, timeout_seconds=2)
        self.assert_fenced(fixture, cohort)

    def test_idle_native_exit_retires_peer_without_waiting_for_another_request(self):
        fixture, cohort = self.fixture()
        self.request(cohort)
        os.kill(cohort.workerPIDs[1], signal.SIGKILL)
        wait_until(lambda: cohort.state == 'failed', description='idle worker exit fencing')
        self.assert_fenced(fixture, cohort)

    def test_all_streamed_tokens_without_peer_completion_cannot_succeed(self):
        fixture, cohort = self.fixture({'1': 'missing_completed'})
        delivered = []
        with self.assertRaises(PersistentCohortError):
            self.request(cohort, timeout_seconds=1,
                         on_token=lambda step, token: delivered.append((step, token)))
        self.assertEqual([step for step, _ in delivered], [0, 1, 2])
        fixture.wait_for_active('request-1')
        self.assert_fenced(fixture, cohort)

    def test_active_deadline_retires_sigterm_ignoring_workers(self):
        fixture, cohort = self.fixture({'0': 'hang_active', '1': 'hang_active'})
        start = time.monotonic()
        with self.assertRaises(PersistentCohortError):
            self.request(cohort, timeout_seconds=1)
        self.assertLess(time.monotonic() - start, 5)
        fixture.wait_for_active('request-1')
        self.assert_fenced(fixture, cohort)

    def test_cancel_from_another_thread_retires_active_epoch(self):
        fixture, cohort = self.fixture({'0': 'hang_active', '1': 'hang_active'})
        thread, outcome = self.run_in_thread(cohort, timeout_seconds=10)
        fixture.wait_for_active('active')
        cohort.cancel()
        thread.join(4)
        self.assertFalse(thread.is_alive(), 'Cancellation left infer() blocked')
        self.assertEqual(len(outcome), 1)
        self.assertEqual(outcome[0][0], 'error')
        self.assertIsInstance(outcome[0][1], PersistentCohortError)
        self.assert_fenced(fixture, cohort)

    def test_concurrent_infer_is_rejected_without_dispatching_second_request(self):
        fixture, cohort = self.fixture({'0': 'hang_active', '1': 'hang_active'})
        thread, _ = self.run_in_thread(cohort, timeout_seconds=10)
        fixture.wait_for_active('active')
        start = time.monotonic()
        with self.assertRaises(RuntimeError):
            self.request(cohort, 'concurrent')
        self.assertLess(time.monotonic() - start, 0.5)
        for rank in (0, 1):
            self.assertEqual([e['request_id'] for e in fixture.events(rank) if e['event'] == 'infer'],
                             ['active'])
        cohort.cancel()
        thread.join(4)
        self.assertFalse(thread.is_alive())
        self.assert_fenced(fixture, cohort)

    def test_callback_exception_retires_epoch_after_only_agreed_token(self):
        fixture, cohort = self.fixture()
        delivered = []

        def fail(step, token):
            delivered.append((step, token))
            raise LookupError('Consumer stopped accepting tokens')

        with self.assertRaises(PersistentCohortError):
            self.request(cohort, on_token=fail)
        self.assertEqual([step for step, _ in delivered], [0])
        self.assert_fenced(fixture, cohort)

    def test_callback_elapsed_deadline_cannot_return_success(self):
        fixture, cohort = self.fixture()
        delivered = []

        def too_slow(step, token):
            delivered.append((step, token))
            time.sleep(1.1)

        with self.assertRaises(PersistentCohortError):
            self.request(cohort, timeout_seconds=1, on_token=too_slow)
        self.assertEqual([step for step, _ in delivered], [0])
        self.assert_fenced(fixture, cohort)

    def test_unresponsive_shutdown_is_bounded_and_close_is_idempotent(self):
        fixture, cohort = self.fixture({'1': 'hang_shutdown'})
        self.request(cohort)
        start = time.monotonic()
        cohort.close()
        self.assertLess(time.monotonic() - start, 6)
        fixture.assert_stopped()
        cohort.close()
        self.assert_fenced(fixture, cohort)

    def test_mismatched_ready_identity_retires_startup_workers(self):
        fixture, cohort = self.fixture({'1': 'wrong_ready_identity'}, start=False)
        with self.assertRaises(PersistentCohortError):
            cohort.start()
        self.assert_fenced(fixture, cohort)

    def test_cancel_and_close_while_awaiting_ready_retire_all_started_processes(self):
        for operation in ('cancel', 'close'):
            with self.subTest(operation=operation):
                fixture, cohort = self.fixture({'0': 'hang_ready', '1': 'hang_ready'}, start=False)
                outcome = []

                def start():
                    try:
                        outcome.append(('ready', cohort.start()))
                    except BaseException as error:
                        outcome.append(('error', error))

                thread = threading.Thread(target=start, daemon=True)
                thread.start()
                self.addCleanup(thread.join, 4)
                wait_until(lambda: len(fixture.process_ids()) == 4,
                           description='both native workers awaiting ready')
                self.assertEqual(cohort.state, 'starting')
                getattr(cohort, operation)()
                thread.join(4)
                self.assertFalse(thread.is_alive(), 'Startup remained blocked after retirement')
                self.assertEqual(len(outcome), 1)
                self.assertEqual(outcome[0][0], 'error')
                self.assertIsInstance(outcome[0][1], PersistentCohortError)
                self.assert_fenced(fixture, cohort)

    def test_abandoned_callback_return_cannot_restart_callbacks_after_fence(self):
        fixture, cohort = self.fixture()
        entered, release, returned = threading.Event(), threading.Event(), threading.Event()
        delivered = []

        def held_callback(step, token):
            delivered.append((step, token))
            entered.set()
            release.wait(8)
            returned.set()

        thread, outcome = self.run_in_thread(cohort, on_token=held_callback, timeout_seconds=10)
        try:
            self.assertTrue(entered.wait(4), 'First agreed callback never started')
            cohort.cancel()
            thread.join(4)
            self.assertFalse(thread.is_alive(), 'Cancellation waited for blocked user callback')
            self.assertFalse(returned.is_set(), 'Callback was not held across epoch retirement')
            self.assertEqual(len(outcome), 1)
            self.assertEqual(outcome[0][0], 'error')
            self.assertIsInstance(outcome[0][1], PersistentCohortError)
            self.assert_fenced(fixture, cohort)
        finally:
            release.set()
        self.assertTrue(returned.wait(4))
        # The original infer thread has exited, and this pause lets an erroneously
        # restarted callback loop become observable after user code returns.
        time.sleep(0.1)
        self.assertEqual([step for step, _ in delivered], [0])
        self.assert_fenced(fixture, cohort)


if __name__ == '__main__':
    unittest.main()
