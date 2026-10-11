#!/usr/bin/env python3
"""Exercise cross-repository dispatch without network access or credentials."""
from datetime import datetime, timedelta, timezone
import importlib.util
import json
from pathlib import Path
import re
import subprocess
import unittest
from unittest.mock import patch
from urllib.parse import parse_qs, urlsplit

ROOT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location(
    'qualification_dispatch', ROOT / 'scripts/provider_release_qualification/dispatch.py')
dispatch = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(dispatch)
REQUEST_ID = 'a' * 32
PLATFORM_SHA = 'b' * 40
STARTED = datetime(2026, 10, 11, 12, 0, 0, tzinfo=timezone.utc)


def request():
    return {
        'environment': 'prod', 'provider_run_id': '123', 'provider_run_attempt': 3,
        'candidate_run_id': '120', 'candidate_artifact_id': '456',
        'candidate_artifact_digest': 'c' * 64,
        'candidate_payload_sha256': 'd' * 64, 'candidate_provenance_sha256': 'e' * 64,
        'candidate_source_commit': 'f' * 40,
        'static27': {'artifact_id': '457', 'artifact_digest': '1' * 64, 'attempt': 2},
        'static26': {'artifact_id': '458', 'artifact_digest': 'sha256:' + '2' * 64, 'attempt': 3},
    }


def run(**changes):
    result = {
        'id': 789, 'display_title': 'Provider qualification ' + REQUEST_ID,
        'head_sha': PLATFORM_SHA, 'path': dispatch.WORKFLOW_PATH,
        'event': 'workflow_dispatch', 'repository': {'full_name': dispatch.PLATFORM_REPOSITORY},
        'created_at': STARTED.strftime('%Y-%m-%dT%H:%M:%SZ'),
        'status': 'completed', 'conclusion': 'success',
    }
    result.update(changes)
    return result


class FakeGitHub:
    def __init__(self, snapshots, detail=None):
        self.snapshots = snapshots
        self.detail = detail
        self.calls = []
        self.current = []

    def __call__(self, method, path, payload=None, *, timeout):
        self.calls.append((method, path, payload, timeout))
        if method == 'POST':
            return None
        if '/runs?' in path:
            self.current = self.snapshots.pop(0) if len(self.snapshots) > 1 else self.snapshots[0]
            return {'total_count': len(self.current), 'workflow_runs': self.current}
        return self.detail if self.detail is not None else self.current[0]


class DispatchTests(unittest.TestCase):
    def wait(self, api, **kwargs):
        elapsed = [0]

        def sleep(seconds):
            elapsed[0] += seconds

        return dispatch.dispatch_and_wait(
            request(), 'qualification/v1', PLATFORM_SHA,
            api=api, request_id=REQUEST_ID, utcnow=lambda: STARTED,
            monotonic=lambda: elapsed[0], sleep=sleep, **kwargs)

    def test_success_waits_for_exact_correlated_run(self):
        unrelated = run(id=999, display_title='Unrelated successful workflow')
        api = FakeGitHub([[unrelated], [run(status='in_progress', conclusion=None)], [run()]])
        self.assertEqual(self.wait(api), 789)
        method, path, payload, timeout = api.calls[0]
        self.assertEqual((method, path), ('POST', dispatch.WORKFLOW_API + '/dispatches'))
        self.assertEqual(set(payload), {'ref', 'inputs'})
        self.assertEqual(payload['ref'], 'qualification/v1')
        self.assertEqual(set(payload['inputs']), {'request_id', 'request'})
        self.assertEqual(payload['inputs']['request_id'], REQUEST_ID)
        wire = json.loads(payload['inputs']['request'])
        self.assertEqual(set(wire), dispatch.REQUEST_FIELDS)
        self.assertEqual(wire, dispatch.validate_request(request()))
        self.assertNotIn(' ', payload['inputs']['request'])
        self.assertEqual(wire['candidate_artifact_digest'], 'sha256:' + 'c' * 64)
        self.assertEqual(wire['static26']['attempt'], 3)
        self.assertIs(type(wire['provider_run_attempt']), int)
        self.assertLessEqual(timeout, 30)
        query = parse_qs(urlsplit(api.calls[1][1]).query)
        self.assertEqual(query['event'], ['workflow_dispatch'])
        self.assertEqual(query['created'], ['>=2026-10-11T11:59:00Z'])
        self.assertEqual(sum('/runs?' in call[1] for call in api.calls), 3)

    def test_request_id_is_generated_with_128_bits_of_randomness(self):
        api = FakeGitHub([[run()]])
        with patch.object(dispatch.secrets, 'token_hex', return_value=REQUEST_ID) as token:
            dispatch.dispatch_and_wait(request(), 'qualification/v1', PLATFORM_SHA, api=api, utcnow=lambda: STARTED)
        token.assert_called_once_with(16)

    def test_all_unsuccessful_conclusions_abort(self):
        for conclusion in ('failure', 'cancelled', 'timed_out', 'skipped', 'neutral',
                           'action_required', 'stale', None):
            with self.subTest(conclusion=conclusion), self.assertRaisesRegex(RuntimeError, 'did not succeed'):
                self.wait(FakeGitHub([[run(conclusion=conclusion)]]))

    def test_tampered_run_identity_is_rejected_in_listing_and_detail(self):
        for changes in ({'head_sha': '0' * 40}, {'path': '.github/workflows/other.yml'},
                        {'event': 'push'}, {'repository': {'full_name': 'attacker/platform'}},
                        {'repository': None}, {'id': True}, {'status': 'unknown'}):
            for in_detail in (False, True):
                with self.subTest(changes=changes, in_detail=in_detail), self.assertRaises(ValueError):
                    self.wait(FakeGitHub([[run() if in_detail else run(**changes)]],
                                        detail=run(**changes) if in_detail else None))

    def test_detail_must_keep_the_same_correlation_and_run_id(self):
        for changes in ({'id': 790}, {'display_title': 'Provider qualification ' + 'c' * 32}):
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                self.wait(FakeGitHub([[run()]], detail=run(**changes)))

    def test_ambiguous_correlation_fails_even_if_one_run_succeeds(self):
        with self.assertRaisesRegex(ValueError, 'Ambiguous'):
            self.wait(FakeGitHub([[run(), run(id=790, conclusion='failure')]]))

    def test_pagination_does_not_hide_duplicate_correlations(self):
        def api(method, path, payload=None, *, timeout):
            if method == 'POST':
                return None
            page = parse_qs(urlsplit(path).query)['page'][0]
            runs = [run()] + [run(id=i, display_title='Other') for i in range(99)] if page == '1' else [run(id=790)]
            return {'total_count': 101, 'workflow_runs': runs}

        with self.assertRaisesRegex(ValueError, 'Ambiguous'):
            self.wait(api)

    def test_incomplete_or_capped_listings_fail_closed(self):
        for result in ({'total_count': 1001, 'workflow_runs': [run()]},
                       {'total_count': 101, 'workflow_runs': []},
                       {'total_count': 1, 'workflow_runs': [None]},
                       {'total_count': 1, 'workflow_runs': {}}, None):
            def api(method, path, payload=None, *, timeout):
                return None if method == 'POST' else result
            with self.subTest(result=result), self.assertRaises(ValueError):
                self.wait(api)

    def test_creation_time_has_at_most_one_minute_of_clock_slack(self):
        for seconds in (-61, 3361):
            created = (STARTED + timedelta(seconds=seconds)).strftime('%Y-%m-%dT%H:%M:%SZ')
            with self.subTest(seconds=seconds), self.assertRaisesRegex(ValueError, 'creation time'):
                self.wait(FakeGitHub([[run(created_at=created)]]))
        created = (STARTED - timedelta(seconds=60)).strftime('%Y-%m-%dT%H:%M:%SZ')
        self.assertEqual(self.wait(FakeGitHub([[run(created_at=created)]])), 789)

    def test_missing_or_running_qualification_times_out(self):
        for snapshot in ([], [run(status='in_progress', conclusion=None)]):
            with self.subTest(snapshot=snapshot), self.assertRaisesRegex(TimeoutError, 'Timed out'):
                self.wait(FakeGitHub([snapshot]), timeout=16)

    def test_dispatch_api_failure_aborts_without_retrying(self):
        calls = []

        def api(method, path, payload=None, *, timeout):
            calls.append(method)
            raise RuntimeError('GitHub unavailable')

        with self.assertRaisesRegex(RuntimeError, 'unavailable'):
            self.wait(api)
        self.assertEqual(calls, ['POST'])

    def test_invalid_ref_sha_and_request_never_dispatch(self):
        for ref in ('', None, 'main;whoami', 'refs/heads/master', 'refs/tags/v1', '../v1',
                    'a//b', 'v1.lock', 'v1.', '.hidden', 'a/../b', 'b' * 40, 'a\nb',
                    'master', 'v1', 'qualification/v0', 'qualification/v01', 'qualification/v1.2-rc_1'):
            with self.subTest(ref=ref), self.assertRaises(ValueError):
                dispatch.validate_trust(ref, PLATFORM_SHA)
        for sha in ('', None, 'main', 'b' * 39, 'B' * 40, 'z' * 40):
            with self.subTest(sha=sha), self.assertRaises(ValueError):
                dispatch.validate_trust('qualification/v1', sha)
        dispatch.validate_trust('qualification/v12', PLATFORM_SHA)
        for changes in ({'policy': 'caller-controlled'}, {'environment': 'stage'},
                        {'provider_run_attempt': True}, {'provider_run_attempt': '1'},
                        {'candidate_run_id': 123}, {'candidate_source_commit': 'main'},
                        {'candidate_artifact_digest': 'sha512:' + 'a' * 64},
                        {'static26': {'artifact_id': '1', 'artifact_digest': '1' * 64, 'attempt': 0}},
                        {'static26': {'artifact_id': '1', 'artifact_digest': '1' * 64, 'attempt': 4}}):
            value = request()
            value.update(changes)
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                dispatch.validate_request(value)

    def test_environment_preserves_candidate_and_static_producer_attempts(self):
        value = request()
        environ = {'RELEASE_ENVIRONMENT': 'prod', 'GITHUB_RUN_ID': '123', 'GITHUB_RUN_ATTEMPT': '3'}
        for field, data in value.items():
            if field.startswith('candidate_'):
                environ['RELEASE_' + field.upper()] = data
        for major in (26, 27):
            for field, data in value[f'static{major}'].items():
                environ[f'RELEASE_STATIC{major}_' + field.upper()] = str(data)
        self.assertEqual(dispatch.request_from_environment(environ), dispatch.validate_request(value))
        workflow = (ROOT / '.github/workflows/release-swift.yml').read_text()
        job = re.search(r'^  qualify-release:\n(.*?)(?=^  [\w-]+:|\Z)', workflow, re.M | re.S).group(1)
        for name in environ.keys() - {'GITHUB_RUN_ID', 'GITHUB_RUN_ATTEMPT'}:
            self.assertIn(name + ':', job)
        del environ['RELEASE_STATIC27_ATTEMPT']
        with self.assertRaises(ValueError):
            dispatch.request_from_environment(environ)

    def test_api_uses_github_com_and_json_stdin_with_bounded_timeout(self):
        result = subprocess.CompletedProcess([], 0, stdout='{"id":789}\n', stderr='')
        with patch.object(dispatch.subprocess, 'run', return_value=result) as invoke:
            self.assertEqual(dispatch.github_api('POST', 'test/path', {'request': 'test'}, timeout=7), {'id': 789})
        args, kwargs = invoke.call_args
        self.assertEqual(args[0][:5], ['gh', 'api', '--hostname', 'github.com', '--method'])
        self.assertEqual(json.loads(kwargs['input']), {'request': 'test'})
        self.assertEqual(kwargs['timeout'], 7)
        self.assertTrue(kwargs['check'])
        self.assertTrue(kwargs['capture_output'])

    def test_workflow_is_protected_and_only_exposes_token_to_dispatch(self):
        workflow = (ROOT / '.github/workflows/release-swift.yml').read_text()
        match = re.search(r'^  qualify-release:\n(.*?)(?=^  [\w-]+:|\Z)', workflow, re.M | re.S)
        self.assertIsNotNone(match)
        job = match.group(1)
        self.assertIn('runs-on: ubuntu-24.04', job)
        self.assertIn('timeout-minutes: 60', job)
        self.assertIn('environment: ${{ needs.resolve-env.outputs.environment }}', job)
        self.assertIn('permissions:\n      contents: read\n    steps:', job)
        self.assertIn('persist-credentials: false', job)
        self.assertNotIn('uses: Layr-Labs/darkbloom-platform', job)
        self.assertNotIn('actions: write', job)
        self.assertNotIn('download', job)
        self.assertNotIn('continue-on-error', job)
        self.assertEqual(job.count('secrets.'), 1)
        self.assertIn('GH_TOKEN: ${{ secrets.PLATFORM_QUALIFICATION_DISPATCH_TOKEN }}', job)
        for variable in ('PLATFORM_QUALIFICATION_REF', 'PLATFORM_QUALIFICATION_SHA'):
            self.assertIn(variable + ': ${{ vars.' + variable + ' }}', job)
        for major in (26, 27):
            self.assertIn(f'RELEASE_STATIC{major}_ATTEMPT: ${{{{ needs.validate-signed-macos{major}.outputs.qualification_attempt }}}}', job)
            self.assertIn(f"needs.validate-signed-macos{major}.result == 'success'", job)
        self.assertIn('run: python3 scripts/provider_release_qualification/dispatch.py', job)


if __name__ == '__main__':
    unittest.main()
