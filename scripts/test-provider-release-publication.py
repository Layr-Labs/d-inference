#!/usr/bin/env python3
"""Exercise publication ordering/retries without credentials or live writes."""
import contextlib
import functools
import http.server
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
from types import SimpleNamespace
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location('publication', Path(__file__).with_name('provider-release-publication.py'))
PUB = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PUB)


class PublicationFixture(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        bundle = self.base / PUB.BUNDLE
        bundle.write_bytes(b'exact signed bundle')
        self.root = self.base / 'artifact'
        self.env = {'VERSION': '0.9.8', 'ENV_PREFIX': 'prod', 'BINARY_HASH': 'a'*64, 'BUNDLE_HASH': PUB.sha256(bundle),
                    'METALLIB_HASH': 'b'*64, 'CODE_DIRECTORY_HASH': 'c'*64, 'GITHUB_SHA': 'd'*40,
                    'GITHUB_RUN_ID': '123', 'GITHUB_REPOSITORY': 'Layr-Labs/d-inference',
                    'GITHUB_REF_NAME': 'v0.9.8', 'R2_PUBLIC_URL': 'https://releases.example',
                    'COORDINATOR_URL': 'https://coordinator.example', 'RELEASE_KEY': 'never-log',
                    'R2_BUCKET': 'example', 'R2_ENDPOINT': 'https://r2.example'}
        self.payload = PUB.prepare(self.root, bundle, self.env)


class PublicationTests(PublicationFixture):
    def test_stage_is_not_publication_and_requires_operator_evidence(self):
        q = json.loads((self.root / 'qualification-request.json').read_text())
        self.assertEqual(q['evidence'], '')
        self.assertNotIn('approved_by', q)
        self.assertEqual(q['release']['binary_hash'], self.payload['binary_hash'])
        with patch.object(PUB, 'upload') as upload, patch.object(PUB, 'coordinator') as api:
            PUB.stage(self.root, self.env)
            api.assert_not_called()
            self.assertIn('/artifacts/' + self.payload['bundle_hash'] + '/', upload.call_args.args[1])
            self.assertNotIn('/latest/', upload.call_args.args[1])

    def test_r2_stage_retry_reuses_retained_bytes_without_publication(self):
        before = {p.name: p.read_bytes() for p in self.root.iterdir()}
        with patch.object(PUB, 'upload', side_effect=[RuntimeError('R2 unavailable'), None]) as upload, \
                patch.object(PUB, 'prepare') as prepare, patch.object(PUB, 'coordinator') as api, \
                patch.object(PUB, 'publish_github_release') as github:
            with self.assertRaisesRegex(RuntimeError, 'R2 unavailable'):
                PUB.stage(self.root, self.env)
            PUB.stage(self.root, dict(self.env, GITHUB_RUN_ATTEMPT='2'))
            self.assertEqual(upload.call_args_list[0].args[:2], upload.call_args_list[1].args[:2])
            prepare.assert_not_called()
            api.assert_not_called()
            github.assert_not_called()
        self.assertEqual({p.name: p.read_bytes() for p in self.root.iterdir()}, before)

    def test_registration_failure_cannot_advance_aliases_or_github(self):
        with patch.object(PUB, 'coordinator', side_effect=RuntimeError('unqualified')), patch.object(PUB, 'upload') as upload, patch.object(PUB, 'publish_github_release') as github:
            with self.assertRaisesRegex(RuntimeError, 'unqualified'):
                PUB.publish(self.root, self.env)
            upload.assert_not_called()
            github.assert_not_called()

    def test_registration_and_readiness_precede_all_publication(self):
        events = []
        def api(env, path, payload=None):
            events.append(path)
            return self.payload
        def upload(root, key, env):
            events.append(key)
        with patch.object(PUB, 'coordinator', side_effect=api), patch.object(PUB, 'upload', side_effect=upload), patch.object(PUB, 'publish_github_release') as github:
            PUB.publish(self.root, self.env)
        self.assertEqual(events[:2], ['/v1/releases', '/v1/releases/latest?platform=macos-arm64'])
        self.assertEqual(len(events), 4)
        self.assertTrue(all('/latest/' in e for e in events[2:]))
        self.assertTrue(github.call_args.args[-1])

    def test_retry_uses_same_bytes_and_old_release_never_rolls_back_latest(self):
        before = PUB.sha256(self.root / PUB.BUNDLE)
        def api(env, path, payload=None):
            return {'version': '1.0.0', 'bundle_hash': 'f'*64}
        with patch.object(PUB, 'coordinator', side_effect=api), patch.object(PUB, 'upload') as upload, patch.object(PUB, 'publish_github_release') as github:
            for _ in range(2):
                PUB.publish(self.root, self.env)
            upload.assert_not_called()
            self.assertEqual(github.call_count, 2)
            self.assertFalse(github.call_args.args[-1])
        self.assertEqual(PUB.sha256(self.root / PUB.BUNDLE), before)

    def test_source_run_origin_and_bundle_substitution_fail_before_io(self):
        for field, value in [('source_commit', 'e'*40), ('ci_run_id', '456'), ('url', 'https://attacker.example/bundle'), ('require_app_attest_qualification', False)]:
            with self.subTest(field=field):
                modified = dict(self.payload, **{field: value})
                (self.root / 'release-payload.json').write_text(json.dumps(modified))
                with patch.object(PUB, 'coordinator') as api, self.assertRaises(ValueError):
                    PUB.publish(self.root, self.env)
                api.assert_not_called()
        (self.root / 'release-payload.json').write_text(json.dumps(self.payload))
        (self.root / PUB.BUNDLE).write_bytes(b'wrong signed bytes')
        with patch.object(PUB, 'coordinator') as api, self.assertRaisesRegex(ValueError, 'digest mismatch'):
            PUB.publish(self.root, self.env)
        api.assert_not_called()

    def test_cross_coordinator_convergence_never_silently_skips_latest(self):
        with patch.object(PUB.time, 'sleep'), patch.object(PUB, 'coordinator', side_effect=[
                PUB.ReadinessPending(), {'version': '0.9.7'}, self.payload]):
            self.assertTrue(PUB.await_latest(self.env, self.payload))
        with patch.object(PUB.time, 'sleep'), patch.object(PUB, 'coordinator', return_value={'version': '0.9.7'}):
            with self.assertRaisesRegex(RuntimeError, 'not converged'):
                PUB.await_latest(self.env, self.payload)

    def test_tag_annotation_is_retained_as_data_not_executable_code(self):
        repo = self.base / 'tag-repository'
        # CI has no global committer identity. Configure both fixture commands,
        # and suppress machine-wide config so a developer's defaults cannot
        # hide an undeclared dependency (notably the annotated-tag identity).
        git = ['git', '-c', 'user.name=Release Test', '-c', 'user.email=test@example.com']
        git_env = dict(os.environ, GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM='1')
        subprocess.run(git + ['init', '-q', str(repo)], env=git_env, check=True)
        subprocess.run(git + ['-c', 'commit.gpgsign=false', 'commit', '--allow-empty', '-qm', 'Fixture'],
                       cwd=repo, env=git_env, check=True)
        marker = self.base / 'must-not-exist'
        message = 'Restore release approvals\n\nDetailed notes with "quotes", `backticks`, and $(touch ' + str(marker) + ').\nSecond paragraph: café.\n'
        subprocess.run(git + ['-c', 'tag.gpgsign=false', 'tag', '-a', self.env['GITHUB_REF_NAME'], '-F', '-'],
                       input=message, text=True, cwd=repo, env=git_env, check=True)
        env = dict(self.env, GITHUB_REF_TYPE='tag')
        with patch.dict(os.environ, {'GIT_DIR': str(repo / '.git'), 'GIT_WORK_TREE': str(repo)}):
            root = self.base / 'tagged-artifact'
            payload = PUB.prepare(root, self.base / PUB.BUNDLE, env)
        self.assertEqual(payload['changelog'], message.strip())
        self.assertEqual(json.loads((root / 'release-payload.json').read_text())['changelog'], message.strip())
        self.assertEqual(json.loads((root / 'qualification-request.json').read_text())['release']['changelog'], message.strip())
        self.assertFalse(marker.exists())
        self.assertEqual(PUB.release_changelog(dict(env, GITHUB_REF_TYPE='branch')), 'Release v0.9.8')


class GitHubPublicationTests(PublicationFixture):
    def fake_github(self, release=None, fail_at=None, content=None):
        self.release = release
        self.content = (self.root / PUB.BUNDLE).read_bytes() if content is None else content
        self.events = []
        self.fail_at = fail_at

        def fail(point, args):
            if self.fail_at == point:
                self.fail_at = None
                raise subprocess.CalledProcessError(1, args)

        def run(args, **kwargs):
            op = args[2]
            self.events.append((op, args))
            if op == 'view':
                return SimpleNamespace(returncode=1 if self.release is None else 0, stdout=json.dumps(self.release))
            if op == 'create':
                self.assertIn('--draft', args)
                self.release = {'tagName': self.env['GITHUB_REF_NAME'], 'isDraft': True, 'assets': []}
                fail('create', args)
            elif op == 'upload':
                self.assertTrue(self.release['isDraft'])
                if self.release['assets']:
                    self.assertEqual(self.release['assets'][0]['state'], 'starter')
                    self.assertIn('--clobber', args)
                else:
                    self.assertNotIn('--clobber', args)
                self.release['assets'] = [{'name': PUB.BUNDLE, 'state': 'starter'}]
                fail('upload_started', args)
                self.release['assets'][0]['state'] = 'uploaded'
                fail('upload_finished', args)
            elif op == 'download':
                self.assertEqual(self.release['assets'][0]['state'], 'uploaded')
                (Path(args[args.index('--dir') + 1]) / PUB.BUNDLE).write_bytes(self.content)
            elif op == 'edit':
                self.assertIn('--draft=false', args)
                self.release['isDraft'] = False
                fail('edit', args)
            else:
                self.fail('Unexpected gh operation: ' + op)
            return SimpleNamespace(returncode=0)
        return patch.object(PUB.subprocess, 'run', side_effect=run)

    def publish_github(self, is_latest=True):
        PUB.publish_github_release(self.root, PUB.BUNDLE, self.payload['bundle_hash'], self.env, is_latest)

    def test_partial_creation_upload_and_publish_resume_with_exact_bytes(self):
        for point in ['create', 'upload_started', 'upload_finished', 'edit']:
            with self.subTest(point=point), self.fake_github(fail_at=point):
                with self.assertRaises(subprocess.CalledProcessError):
                    self.publish_github()
                self.publish_github()
                self.assertFalse(self.release['isDraft'])
                self.assertEqual(sum(op == 'create' for op, _ in self.events), 1)
                self.assertEqual(sum(op == 'upload' for op, _ in self.events), 2 if point == 'upload_started' else 1)
                self.assertEqual(sum(op == 'edit' for op, _ in self.events), 1)
                # A completed publication retry only verifies existing bytes.
                self.events.clear()
                self.publish_github()
                self.assertEqual([op for op, _ in self.events], ['view', 'download'])

    def test_existing_draft_with_verified_asset_is_published_without_reupload(self):
        release = {'tagName': self.env['GITHUB_REF_NAME'], 'isDraft': True,
                   'assets': [{'name': PUB.BUNDLE, 'state': 'uploaded'}]}
        with self.fake_github(release):
            self.publish_github(is_latest=False)
        self.assertEqual([op for op, _ in self.events], ['view', 'download', 'edit', 'view'])
        self.assertIn('--latest=false', self.events[2][1])

    def test_completed_mismatched_asset_is_never_overwritten_or_published(self):
        for draft in [True, False]:
            release = {'tagName': self.env['GITHUB_REF_NAME'], 'isDraft': draft,
                       'assets': [{'name': PUB.BUNDLE, 'state': 'uploaded'}]}
            with self.subTest(draft=draft), self.fake_github(release, content=b'other signed artifact'):
                with self.assertRaisesRegex(ValueError, 'different signed bytes'):
                    self.publish_github()
                self.assertEqual([op for op, _ in self.events], ['view', 'download'])

    def test_incomplete_published_release_is_not_mutated(self):
        with self.fake_github({'tagName': self.env['GITHUB_REF_NAME'], 'isDraft': False, 'assets': []}):
            with self.assertRaisesRegex(ValueError, 'refusing to modify'):
                self.publish_github()
        self.assertEqual([op for op, _ in self.events], ['view'])


# --- #1177 T2: qualification-wait operations (await/status/summary/evidence/ ---
# --- resume-source/verify), and the publish/validate identity-binding change. ---
# These operations and the identity-binding change do not exist on this branch
# yet; every test below must fail (or error on an uncaught SystemExit(2) from
# argparse rejecting the still-unknown --operation value) until they land.


def run_main(argv, env_updates, remove=(), clear_env=False):
    """Invoke PUB.main() with a patched argv/environment, capturing stdout.

    Any exception main() raises (including SystemExit, e.g. argparse rejecting
    an operation name that does not exist yet) propagates to the caller.
    """
    buf = io.StringIO()
    with patch.object(sys, 'argv', ['provider-release-publication.py'] + list(argv)), \
            patch.dict(os.environ, env_updates, clear=clear_env):
        for key in remove:
            os.environ.pop(key, None)
        with contextlib.redirect_stdout(buf):
            PUB.main()
    return buf.getvalue()


class FakeCoordinator:
    """A real local HTTP server standing in for the coordinator.

    This drives await/status/publish through real urllib request/response
    handling, so the tests do not need to guess the internal exception shape
    the new code will use for HTTP-level outcomes (503/404/405).
    """

    def __init__(self):
        self.calls = []
        self.responses = {}
        outer = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def _handle(self, method):
                length = int(self.headers.get('Content-Length', 0) or 0)
                raw = self.rfile.read(length) if length else b''
                try:
                    body = json.loads(raw) if raw else None
                except ValueError:
                    body = raw
                outer.calls.append((method, self.path, body))
                queue = outer.responses.get(self.path)
                if not queue:
                    self.send_response(404)
                    self.end_headers()
                    return
                # Keep the last queued response "sticky" so a poll loop that
                # runs one extra iteration (e.g. right at a timeout boundary)
                # gets a deterministic answer instead of an unrelated 404.
                status, json_body = queue[0] if len(queue) == 1 else queue.pop(0)
                self.send_response(status)
                if json_body is not None:
                    data = json.dumps(json_body).encode()
                    self.send_header('Content-Type', 'application/json')
                    self.send_header('Content-Length', str(len(data)))
                    self.end_headers()
                    self.wfile.write(data)
                else:
                    self.end_headers()

            def do_GET(self):
                self._handle('GET')

            def do_POST(self):
                self._handle('POST')

            def log_message(self, *args):
                pass

        self.server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    @property
    def url(self):
        return f'http://127.0.0.1:{self.server.server_address[1]}'

    def queue(self, path, *responses):
        self.responses.setdefault(path, []).extend(responses)

    def paths_called(self):
        return [path for _method, path, _body in self.calls]

    def stop(self):
        self.server.shutdown()
        self.server.server_close()


class QualificationAwaitTests(PublicationFixture):
    """P1-P4: the `await` operation polls POST /v1/releases/qualification."""

    def setUp(self):
        super().setUp()
        self.coord = FakeCoordinator()
        self.addCleanup(self.coord.stop)
        self.env = dict(self.env, COORDINATOR_URL=self.coord.url,
                         QUALIFICATION_POLL_SECONDS='0', QUALIFICATION_WAIT_MINUTES='60')

    def run_await(self, env=None):
        return run_main(['await', '--directory', str(self.root)], env if env is not None else self.env)

    # P1
    def test_approved_returns_without_registering_or_uploading(self):
        self.coord.queue('/v1/releases/qualification',
                          (200, {'status': 'approved', 'binary_hash': self.payload['binary_hash'],
                                 'approved_by': 'admin@example.com', 'approved_at': '2026-09-24T00:00:00Z',
                                 'evidence': 'darkbloom qualification v1 evidence text'}))
        with patch.object(PUB, 'upload') as upload:
            self.run_await()
        upload.assert_not_called()
        self.assertNotIn('/v1/releases', self.coord.paths_called())
        self.assertEqual(self.coord.paths_called().count('/v1/releases/qualification'), 1)

    # P2
    def test_pending_pending_approved_returns_after_retries(self):
        self.coord.queue('/v1/releases/qualification',
                          (200, {'status': 'pending'}), (200, {'status': 'pending'}),
                          (200, {'status': 'approved', 'binary_hash': self.payload['binary_hash'],
                                 'approved_by': 'admin', 'approved_at': 'now', 'evidence': 'e'}))
        with patch.object(PUB, 'upload') as upload:
            self.run_await()
        upload.assert_not_called()
        self.assertNotIn('/v1/releases', self.coord.paths_called())
        self.assertEqual(self.coord.paths_called().count('/v1/releases/qualification'), 3)

    def test_always_pending_raises_qualification_timeout(self):
        exc_cls = getattr(PUB, 'QualificationTimeout', None)
        self.assertIsNotNone(exc_cls, 'PUB.QualificationTimeout does not exist yet')
        self.coord.queue('/v1/releases/qualification', (200, {'status': 'pending'}))
        env = dict(self.env, QUALIFICATION_WAIT_MINUTES='0')
        with patch.object(PUB, 'upload') as upload:
            with self.assertRaises(exc_cls) as cm:
                self.run_await(env)
        self.assertIn('qualification timeout', str(cm.exception).lower())
        upload.assert_not_called()
        self.assertNotIn('/v1/releases', self.coord.paths_called())

    # P3
    def test_revoked_raises_on_first_poll(self):
        self.coord.queue('/v1/releases/qualification',
                          (200, {'status': 'revoked', 'revoked_by': 'admin', 'revoked_at': 'now',
                                 'revocation_reason': 'bytes compromised'}))
        with patch.object(PUB, 'upload') as upload:
            with self.assertRaises(Exception) as cm:
                self.run_await()
        self.assertIn('revoked', str(cm.exception).lower())
        upload.assert_not_called()
        self.assertEqual(self.coord.paths_called().count('/v1/releases/qualification'), 1)
        self.assertNotIn('/v1/releases', self.coord.paths_called())

    def test_mismatched_raises_on_first_poll_and_names_fields(self):
        self.coord.queue('/v1/releases/qualification',
                          (200, {'status': 'mismatched', 'mismatched_fields': ['bundle_hash', 'source_commit']}))
        with patch.object(PUB, 'upload') as upload:
            with self.assertRaises(Exception) as cm:
                self.run_await()
        message = str(cm.exception)
        self.assertIn('bundle_hash', message)
        self.assertIn('source_commit', message)
        upload.assert_not_called()
        self.assertEqual(self.coord.paths_called().count('/v1/releases/qualification'), 1)
        self.assertNotIn('/v1/releases', self.coord.paths_called())

    def test_revoked_and_mismatched_messages_differ(self):
        messages = {}
        for status, extra in [('revoked', {'revoked_by': 'admin', 'revoked_at': 'now',
                                            'revocation_reason': 'bytes compromised'}),
                               ('mismatched', {'mismatched_fields': ['bundle_hash']})]:
            coord = FakeCoordinator()
            self.addCleanup(coord.stop)
            coord.queue('/v1/releases/qualification', (200, dict({'status': status}, **extra)))
            env = dict(self.env, COORDINATOR_URL=coord.url)
            with patch.object(PUB, 'upload'):
                with self.assertRaises(Exception) as cm:
                    self.run_await(env)
            messages[status] = str(cm.exception)
        self.assertNotEqual(messages['revoked'], messages['mismatched'])

    # P4
    def test_404_warns_and_returns_without_raising(self):
        self.coord.queue('/v1/releases/qualification', (404, None))
        with patch.object(PUB, 'upload') as upload:
            output = self.run_await()
        self.assertIn('::warning::', output)
        upload.assert_not_called()
        self.assertNotIn('/v1/releases', self.coord.paths_called())

    def test_503_then_approved_retries_and_returns(self):
        self.coord.queue('/v1/releases/qualification', (503, None),
                          (200, {'status': 'approved', 'binary_hash': self.payload['binary_hash'],
                                 'approved_by': 'admin', 'approved_at': 'now', 'evidence': 'e'}))
        with patch.object(PUB, 'upload') as upload:
            self.run_await()
        upload.assert_not_called()
        self.assertEqual(self.coord.paths_called().count('/v1/releases/qualification'), 2)
        self.assertNotIn('/v1/releases', self.coord.paths_called())


class PublishQualificationGateTests(PublicationFixture):
    """P5: `publish` re-checks status before registering."""

    def setUp(self):
        super().setUp()
        self.coord = FakeCoordinator()
        self.addCleanup(self.coord.stop)
        self.env = dict(self.env, COORDINATOR_URL=self.coord.url)

    def _queue_registration_success(self):
        self.coord.queue('/v1/releases', (200, self.payload))
        self.coord.queue('/v1/releases/latest?platform=macos-arm64',
                          (200, {'version': self.payload['version'], 'bundle_hash': self.payload['bundle_hash']}))

    def _assert_never_registered(self):
        self.assertIn('/v1/releases/qualification', self.coord.paths_called())
        self.assertNotIn('/v1/releases', self.coord.paths_called())

    def test_publish_refuses_on_pending_without_registering(self):
        self.coord.queue('/v1/releases/qualification', (200, {'status': 'pending'}))
        with patch.object(PUB, 'upload') as upload, patch.object(PUB, 'publish_github_release') as github:
            with self.assertRaises(Exception):
                PUB.publish(self.root, self.env)
        upload.assert_not_called()
        github.assert_not_called()
        self._assert_never_registered()

    def test_publish_refuses_on_revoked_without_registering(self):
        self.coord.queue('/v1/releases/qualification',
                          (200, {'status': 'revoked', 'revoked_by': 'a', 'revoked_at': 'now',
                                 'revocation_reason': 'r'}))
        with patch.object(PUB, 'upload') as upload, patch.object(PUB, 'publish_github_release') as github:
            with self.assertRaises(Exception):
                PUB.publish(self.root, self.env)
        upload.assert_not_called()
        github.assert_not_called()
        self._assert_never_registered()

    def test_publish_refuses_on_mismatched_without_registering(self):
        self.coord.queue('/v1/releases/qualification',
                          (200, {'status': 'mismatched', 'mismatched_fields': ['bundle_hash']}))
        with patch.object(PUB, 'upload') as upload, patch.object(PUB, 'publish_github_release') as github:
            with self.assertRaises(Exception):
                PUB.publish(self.root, self.env)
        upload.assert_not_called()
        github.assert_not_called()
        self._assert_never_registered()

    def test_publish_registers_when_approved(self):
        self.coord.queue('/v1/releases/qualification',
                          (200, {'status': 'approved', 'binary_hash': self.payload['binary_hash'],
                                 'approved_by': 'a', 'approved_at': 'now', 'evidence': 'e'}))
        self._queue_registration_success()
        with patch.object(PUB, 'upload'), patch.object(PUB, 'publish_github_release') as github:
            PUB.publish(self.root, self.env)
        paths = self.coord.paths_called()
        self.assertIn('/v1/releases/qualification', paths)
        self.assertIn('/v1/releases', paths)
        self.assertLess(paths.index('/v1/releases/qualification'), paths.index('/v1/releases'))
        github.assert_called()

    def test_publish_registers_when_qualification_endpoint_is_unsupported_404(self):
        self.coord.queue('/v1/releases/qualification', (404, None))
        self._queue_registration_success()
        with patch.object(PUB, 'upload'), patch.object(PUB, 'publish_github_release') as github:
            PUB.publish(self.root, self.env)
        paths = self.coord.paths_called()
        self.assertIn('/v1/releases/qualification', paths)
        self.assertIn('/v1/releases', paths)
        github.assert_called()


class SummaryOperationTests(PublicationFixture):
    """P6: the `summary` operation."""

    def setUp(self):
        super().setUp()
        self.summary_path = self.base / 'step-summary.md'
        self.env = dict(self.env, GITHUB_RUN_ATTEMPT='1', GITHUB_STEP_SUMMARY=str(self.summary_path))

    def test_summary_lists_identity_digests_request_and_not_yet_run_checks(self):
        run_main(['summary', '--directory', str(self.root)], self.env)
        text = self.summary_path.read_text()
        self.assertIn('Waiting for independent build qualification', text)
        self.assertIn(PUB.BUNDLE, text)
        self.assertIn(self.env['GITHUB_SHA'], text)
        self.assertIn(self.env['GITHUB_RUN_ID'], text)
        self.assertIn(self.env['GITHUB_RUN_ATTEMPT'], text)
        for digest in [self.payload['binary_hash'], self.payload['bundle_hash'],
                       self.payload['metallib_hash'], self.payload['code_directory_hash']]:
            self.assertIn(digest, text)
        request_text = (self.root / 'qualification-request.json').read_text().strip()
        self.assertIn(request_text, text)
        self.assertIn('not yet run', text)
        self.assertNotIn('passed', text.lower())
        self.assertNotIn('failed', text.lower())

    def test_summary_prints_exactly_one_notice_line(self):
        output = run_main(['summary', '--directory', str(self.root)], self.env)
        notice_lines = [line for line in output.splitlines() if '::notice::' in line]
        self.assertEqual(len(notice_lines), 1)

    def test_summary_falls_back_to_stdout_without_step_summary_env(self):
        output = run_main(['summary', '--directory', str(self.root)], self.env, remove=['GITHUB_STEP_SUMMARY'])
        self.assertIn('Waiting for independent build qualification', output)


STATIC_CHECKS = ['bundle-digest', 'binary-digest', 'metallib-digest', 'code-directory',
                  'codesign', 'notarization', 'team-id', 'minimum-macos', 'lane-host']
SMOKE_CHECKS = ['version', 'runtime-smoke']
LIVE_CHECKS = {
    'macos-27': ['app-attest', 'inference', 'graceful-drain', 'accounting'],
    'older-macos': ['inference', 'graceful-drain', 'accounting'],
}


class EvidenceOperationTests(PublicationFixture):
    """P7 / C4: the `evidence` operation."""

    def identity(self):
        ident = {k: self.payload[k] for k in
                 ['version', 'binary_hash', 'bundle_hash', 'metallib_hash', 'code_directory_hash']}
        ident['source_commit'] = self.env['GITHUB_SHA']
        ident['ci_run_id'] = self.env['GITHUB_RUN_ID']
        return ident

    def make_result(self, lane, override_status=None, identity_override=None):
        checks = []
        for name in STATIC_CHECKS:
            checks.append({'name': name, 'level': 'static', 'status': 'passed', 'detail': 'ok'})
        for name in SMOKE_CHECKS:
            checks.append({'name': name, 'level': 'smoke', 'status': 'passed', 'detail': 'ok'})
        for name in LIVE_CHECKS[lane]:
            checks.append({'name': name, 'level': 'live', 'status': 'passed', 'detail': 'ok'})
        if override_status:
            name, status, detail = override_status
            for check in checks:
                if check['name'] == name:
                    check['status'] = status
                    check['detail'] = detail
        identity = identity_override if identity_override is not None else self.identity()
        return {'schema': 'darkbloom.provider-qualification-result/v1', 'lane': lane, 'identity': identity,
                'host': {'macos': '26.2', 'build': '25C56', 'model': 'MacBookPro18,3', 'chip': 'Apple M1 Pro'},
                'levels': ['static', 'smoke', 'live'], 'started_at': '2026-09-24T00:00:00Z',
                'finished_at': '2026-09-24T00:05:00Z', 'checks': checks}

    def write_result(self, name, result):
        path = self.base / name
        path.write_text(json.dumps(result))
        return str(path)

    def request_bytes(self):
        return (self.root / 'qualification-request.json').read_bytes()

    def run_evidence(self, extra_args):
        return run_main(['evidence', '--directory', str(self.root)] + extra_args, self.env)

    def test_all_passed_renders_evidence_and_writes_files(self):
        r27 = self.write_result('result-macos-27.json', self.make_result('macos-27'))
        rold = self.write_result('result-older-macos.json', self.make_result('older-macos'))
        before = self.request_bytes()
        self.run_evidence(['--result', r27, '--result', rold])
        request = json.loads((self.root / 'qualification-request.json').read_text())
        evidence_text = request['evidence']
        self.assertTrue(evidence_text)
        self.assertLessEqual(len(evidence_text.encode()), 4096)
        self.assertIn(self.payload['binary_hash'][:12], evidence_text)
        self.assertIn(self.payload['code_directory_hash'][:12], evidence_text)
        self.assertIn('macos-27', evidence_text)
        self.assertIn('older-macos', evidence_text)
        evidence_path = self.root / 'qualification-evidence.json'
        self.assertTrue(evidence_path.exists())
        json.loads(evidence_path.read_text())  # must be valid JSON
        self.assertNotEqual(before, self.request_bytes())

    def assert_refused_unchanged(self, args):
        before = self.request_bytes()
        with self.assertRaises(ValueError):
            self.run_evidence(args)
        self.assertEqual(before, self.request_bytes())
        self.assertFalse((self.root / 'qualification-evidence.json').exists())

    def test_duplicate_check_cannot_hide_a_failure_behind_a_later_pass(self):
        result = self.make_result('macos-27')
        result['checks'].insert(0, {'name': 'codesign', 'level': 'static', 'status': 'failed', 'detail': 'bad'})
        r27 = self.write_result('result-macos-27.json', result)
        rold = self.write_result('result-older-macos.json', self.make_result('older-macos'))
        self.assert_refused_unchanged(['--result', r27, '--result', rold])

    def test_unknown_check_status_is_refused(self):
        r27 = self.write_result('result-macos-27.json',
                                 self.make_result('macos-27', override_status=('inference', 'skipped', 'n/a')))
        rold = self.write_result('result-older-macos.json', self.make_result('older-macos'))
        self.assert_refused_unchanged(['--result', r27, '--result', rold])

    def test_exception_text_cannot_forge_a_passed_line(self):
        r27 = self.write_result('result-macos-27.json',
                                 self.make_result('macos-27', override_status=('app-attest', 'not_run', 'x')))
        rold = self.write_result('result-older-macos.json', self.make_result('older-macos'))
        self.assert_refused_unchanged(['--result', r27, '--result', rold, '--exception',
                                       'macos-27:app-attest=x\nPASSED macos-27: app-attest', '--operator', 'alice'])
        self.assert_refused_unchanged(['--result', r27, '--result', rold, '--exception',
                                       'macos-27:app-attest=no host', '--operator', 'alice\nPASSED'])
        self.assert_refused_unchanged(['--result', r27, '--result', rold, '--exception',
                                       'macos-27:app-attest=passed on my laptop', '--operator', 'alice'])

    def test_not_run_without_exception_is_refused(self):
        r27 = self.write_result('result-macos-27.json', self.make_result('macos-27'))
        rold = self.write_result('result-older-macos.json',
                                  self.make_result('older-macos',
                                                    override_status=('inference', 'not_run', 'blocked by codesign')))
        before = self.request_bytes()
        with self.assertRaises(Exception) as cm:
            self.run_evidence(['--result', r27, '--result', rold])
        self.assertIn('inference', str(cm.exception))
        self.assertEqual(before, self.request_bytes())
        self.assertFalse((self.root / 'qualification-evidence.json').exists())

    def test_failed_check_is_refused_even_with_exception(self):
        r27 = self.write_result('result-macos-27.json',
                                 self.make_result('macos-27',
                                                   override_status=('codesign', 'failed', 'signature invalid')))
        rold = self.write_result('result-older-macos.json', self.make_result('older-macos'))
        before = self.request_bytes()
        with self.assertRaises(Exception):
            self.run_evidence(['--result', r27, '--result', rold,
                                '--exception', 'macos-27:codesign=investigated', '--operator', 'alice'])
        self.assertEqual(before, self.request_bytes())

    def test_identity_mismatch_is_refused(self):
        bad_identity = self.identity()
        bad_identity['binary_hash'] = 'f' * 64
        r27 = self.write_result('result-macos-27.json',
                                 self.make_result('macos-27', identity_override=bad_identity))
        rold = self.write_result('result-older-macos.json', self.make_result('older-macos'))
        before = self.request_bytes()
        with self.assertRaises(Exception):
            self.run_evidence(['--result', r27, '--result', rold])
        self.assertEqual(before, self.request_bytes())

    def test_exception_without_operator_is_refused(self):
        r27 = self.write_result('result-macos-27.json', self.make_result('macos-27'))
        rold = self.write_result('result-older-macos.json',
                                  self.make_result('older-macos',
                                                    override_status=('graceful-drain', 'not_run', 'operator unavailable')))
        before = self.request_bytes()
        with self.assertRaises(Exception):
            self.run_evidence(['--result', r27, '--result', rold,
                                '--exception', 'older-macos:graceful-drain=env down'])
        self.assertEqual(before, self.request_bytes())

    def test_exception_on_a_passed_check_is_refused(self):
        r27 = self.write_result('result-macos-27.json', self.make_result('macos-27'))
        rold = self.write_result('result-older-macos.json', self.make_result('older-macos'))
        before = self.request_bytes()
        with self.assertRaises(Exception):
            self.run_evidence(['--result', r27, '--result', rold,
                                '--exception', 'older-macos:accounting=skip', '--operator', 'bob'])
        self.assertEqual(before, self.request_bytes())

    def test_exception_line_says_not_run_and_never_passed(self):
        r27 = self.write_result('result-macos-27.json', self.make_result('macos-27'))
        rold = self.write_result('result-older-macos.json',
                                  self.make_result('older-macos',
                                                    override_status=('graceful-drain', 'not_run', 'env unavailable')))
        self.run_evidence(['--result', r27, '--result', rold,
                            '--exception', 'older-macos:graceful-drain=env unavailable', '--operator', 'carol'])
        request = json.loads((self.root / 'qualification-request.json').read_text())
        exception_lines = [line for line in request['evidence'].splitlines() if 'EXCEPTION' in line]
        self.assertEqual(len(exception_lines), 1)
        self.assertIn('NOT RUN', exception_lines[0])
        self.assertNotIn('passed', exception_lines[0].lower())

    def test_huge_exception_reason_still_fits_4096_bytes(self):
        r27 = self.write_result('result-macos-27.json', self.make_result('macos-27'))
        rold = self.write_result('result-older-macos.json',
                                  self.make_result('older-macos',
                                                    override_status=('graceful-drain', 'not_run', 'env unavailable')))
        huge_reason = 'root cause investigation notes: ' + ('x' * 10000)
        self.run_evidence(['--result', r27, '--result', rold,
                            '--exception', 'older-macos:graceful-drain=' + huge_reason, '--operator', 'dana'])
        request = json.loads((self.root / 'qualification-request.json').read_text())
        self.assertLessEqual(len(request['evidence'].encode()), 4096)


class ResumeBindingTests(PublicationFixture):
    """P8 (identity half): validate() binds to SOURCE_SHA/SOURCE_RUN_ID."""

    def test_source_env_overrides_bind_identity_to_the_source_run(self):
        env = dict(self.env, GITHUB_RUN_ID='different-run-id', GITHUB_SHA='f' * 40,
                   SOURCE_RUN_ID=self.env['GITHUB_RUN_ID'], SOURCE_SHA=self.env['GITHUB_SHA'])
        PUB.validate(self.payload, env)  # must not raise

    def test_mismatched_source_env_fails_before_any_network_or_upload(self):
        env = dict(self.env, SOURCE_SHA='f' * 40, SOURCE_RUN_ID='999999')
        with patch.object(PUB, 'coordinator') as api, patch.object(PUB, 'upload') as upload:
            with self.assertRaises(ValueError):
                PUB.stage(self.root, env)
        api.assert_not_called()
        upload.assert_not_called()

    def test_source_sha_takes_precedence_over_a_matching_github_sha(self):
        env = dict(self.env, SOURCE_SHA='f' * 40)  # wrong, even though GITHUB_SHA still matches
        with self.assertRaises(ValueError):
            PUB.validate(self.payload, env)


class ResumeSourceOperationTests(PublicationFixture):
    """P8 (resume-source op): binds identity to `--run-id`'s own head SHA."""

    def setUp(self):
        super().setUp()
        self.output_path = self.base / 'github-output.txt'
        self.output_path.write_text('')
        self.env = dict(self.env, GH_TOKEN='token', GITHUB_OUTPUT=str(self.output_path))

    def run_resume_source(self, run_id='777'):
        return run_main(['resume-source', '--directory', str(self.root), '--run-id', run_id], self.env)

    def fake_gh(self, run_json, artifacts_json=None):
        events = []

        def run(args, **kwargs):
            events.append(args)
            joined = ' '.join(args)
            if '/artifacts' in joined:
                if artifacts_json is None:
                    self.fail('resume-source fetched artifacts before validating the run identity')
                return SimpleNamespace(returncode=0, stdout=json.dumps(artifacts_json), stderr='')
            if '/actions/runs/' in joined:
                return SimpleNamespace(returncode=0, stdout=json.dumps(run_json), stderr='')
            self.fail(f'resume-source made an unexpected call before validating the run: {args}')

        return events, patch.object(PUB.subprocess, 'run', side_effect=run)

    def test_wrong_workflow_path_is_refused_before_any_download(self):
        run_json = {'path': '.github/workflows/other.yml', 'head_sha': self.env['GITHUB_SHA']}
        events, patcher = self.fake_gh(run_json)
        with patcher:
            with self.assertRaises(Exception):
                self.run_resume_source()
        self.assertEqual(len(events), 1)

    def test_wrong_head_sha_is_refused_before_any_download(self):
        run_json = {'path': '.github/workflows/release-swift.yml', 'head_sha': 'e' * 40}
        events, patcher = self.fake_gh(run_json)
        with patcher:
            with self.assertRaises(Exception):
                self.run_resume_source()
        self.assertEqual(len(events), 1)

    def test_no_matching_artifact_is_refused(self):
        run_json = {'path': '.github/workflows/release-swift.yml', 'head_sha': self.env['GITHUB_SHA']}
        artifacts_json = {'artifacts': [{'name': 'unrelated-artifact', 'expired': False}]}
        events, patcher = self.fake_gh(run_json, artifacts_json)
        with patcher:
            with self.assertRaises(Exception):
                self.run_resume_source()

    def test_valid_run_selects_highest_non_expired_attempt(self):
        sha = self.env['GITHUB_SHA']
        run_json = {'path': '.github/workflows/release-swift.yml', 'head_sha': sha}
        artifacts_json = {'artifacts': [
            {'name': f'provider-publication-{sha}-1', 'expired': False},
            {'name': f'provider-publication-{sha}-2', 'expired': False},
            {'name': f'provider-publication-{sha}-3', 'expired': True},
        ]}
        events, patcher = self.fake_gh(run_json, artifacts_json)
        with patcher:
            self.run_resume_source(run_id='777')
        output = self.output_path.read_text()
        self.assertIn('source_run_id=777', output)
        self.assertIn(f'source_sha={sha}', output)
        self.assertRegex(output, r'publication_artifact=.*-2\b')


class VerifyOperationTests(PublicationFixture):
    """P9: the `verify` operation does real downloads against a local server."""

    def setUp(self):
        super().setUp()
        self.serve_dir = self.base / 'r2-origin'
        self.serve_dir.mkdir()
        handler = functools.partial(self.handler_class(), directory=str(self.serve_dir))
        self.file_server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), handler)
        self.file_thread = threading.Thread(target=self.file_server.serve_forever, daemon=True)
        self.file_thread.start()
        self.addCleanup(self.file_server.shutdown)
        self.addCleanup(self.file_server.server_close)
        self.r2_url = f'http://127.0.0.1:{self.file_server.server_address[1]}'

        verify_env = dict(self.env, ENV_PREFIX='dev', R2_PUBLIC_URL=self.r2_url)
        bundle_source = self.base / PUB.BUNDLE
        self.verify_root = self.base / 'verify-artifact'
        self.verify_payload = PUB.prepare(self.verify_root, bundle_source, verify_env)
        self.verify_env = verify_env

        bundle_bytes = (self.verify_root / PUB.BUNDLE).read_bytes()
        object_path = self.serve_dir / PUB.object_key(self.verify_payload)
        object_path.parent.mkdir(parents=True, exist_ok=True)
        object_path.write_bytes(bundle_bytes)
        latest_dir = self.serve_dir / 'releases' / 'latest'
        latest_dir.mkdir(parents=True, exist_ok=True)
        (latest_dir / PUB.BUNDLE).write_bytes(bundle_bytes)
        (latest_dir / 'eigeninference-bundle-macos-arm64.tar.gz').write_bytes(bundle_bytes)

    def handler_class(self):
        return http.server.SimpleHTTPRequestHandler

    def run_verify(self, latest_response):
        with patch.object(PUB, 'coordinator', return_value=latest_response):
            return run_main(['verify', '--directory', str(self.verify_root)], self.verify_env)

    def test_all_surfaces_match(self):
        self.run_verify({'version': self.verify_payload['version'],
                          'bundle_hash': self.verify_payload['bundle_hash']})

    def test_newer_latest_version_skips_alias_checks_without_failing(self):
        self.run_verify({'version': '99.0.0', 'bundle_hash': 'f' * 64})

    def test_same_version_different_bundle_hash_fails(self):
        with self.assertRaises(Exception):
            self.run_verify({'version': self.verify_payload['version'], 'bundle_hash': 'f' * 64})

    def test_flipped_byte_in_an_alias_names_the_surface(self):
        target = self.serve_dir / 'releases' / 'latest' / 'eigeninference-bundle-macos-arm64.tar.gz'
        data = bytearray(target.read_bytes())
        data[0] ^= 0xFF
        target.write_bytes(bytes(data))
        with self.assertRaises(Exception) as cm:
            self.run_verify({'version': self.verify_payload['version'],
                              'bundle_hash': self.verify_payload['bundle_hash']})
        self.assertIn('releases/latest/eigeninference-bundle-macos-arm64.tar.gz', str(cm.exception))

    def test_older_latest_means_registration_never_happened(self):
        with self.assertRaises(RuntimeError) as cm:
            self.run_verify({'version': '0.9.7', 'bundle_hash': 'f' * 64})
        self.assertIn('registration', str(cm.exception))


class CloudflareUserAgentHandler(http.server.SimpleHTTPRequestHandler):
    """r2.dev answers the default Python-urllib User-Agent with 403 (error code 1010)."""

    def do_GET(self):
        if self.headers.get('User-Agent', '').startswith('Python-urllib'):
            self.send_response(403)
            self.end_headers()
            self.wfile.write(b'error code: 1010')
            return
        super().do_GET()

    def log_message(self, *args):
        pass


class VerifyBehindCloudflareTests(VerifyOperationTests):
    """Every verify case again, against an origin that rejects the default urllib agent."""

    def handler_class(self):
        return CloudflareUserAgentHandler

    def test_download_error_is_reported_as_an_error_not_a_mismatch(self):
        (self.serve_dir / PUB.object_key(self.verify_payload)).unlink()
        with self.assertRaises(RuntimeError) as cm:
            self.run_verify({'version': self.verify_payload['version'],
                              'bundle_hash': self.verify_payload['bundle_hash']})
        self.assertIn('immutable object (ERROR (HTTPError', str(cm.exception))


class ReviewRegressionTests(PublicationFixture):
    """Findings from the #1177 review: each fails without its fix."""

    def setUp(self):
        super().setUp()
        self.coord = FakeCoordinator()
        self.addCleanup(self.coord.stop)
        self.env = dict(self.env, COORDINATOR_URL=self.coord.url,
                         QUALIFICATION_POLL_SECONDS='0', QUALIFICATION_WAIT_MINUTES='60')

    def dev_root(self):
        env = dict(self.env, ENV_PREFIX='dev')
        root = self.base / 'dev-artifact'
        PUB.prepare(root, self.base / PUB.BUNDLE, env)
        return root, env

    def test_dev_payload_does_not_wait_for_an_approval_it_does_not_need(self):
        root, env = self.dev_root()
        self.coord.queue('/v1/releases/qualification', (200, {'status': 'pending'}))
        out = run_main(['await', '--directory', str(root)], env)
        self.assertEqual(self.coord.paths_called().count('/v1/releases/qualification'), 1)
        payload = json.loads((root / 'release-payload.json').read_text())
        self.assertEqual(PUB.qualification_gate(env, payload), {'status': 'not_required'})

    def test_prod_payload_still_waits_when_pending(self):
        self.coord.queue('/v1/releases/qualification', (200, {'status': 'pending'}))
        with self.assertRaises(PUB.QualificationTimeout):
            run_main(['await', '--directory', str(self.root)], dict(self.env, QUALIFICATION_WAIT_MINUTES='0.001'))

    def test_unreachable_coordinator_keeps_the_wait_instead_of_skipping_it(self):
        calls = []

        def status(env, payload):
            calls.append(1)
            if len(calls) < 3:
                raise PUB.CoordinatorUnreachable('connection refused')
            return {'status': 'approved', 'approved_by': 'a', 'approved_at': 't', 'evidence': 'e'}
        with patch.object(PUB, 'qualification_status', side_effect=status):
            run_main(['await', '--directory', str(self.root)], self.env)
        self.assertEqual(len(calls), 3)

    def test_wait_window_is_clamped_to_the_job_timeout(self):
        self.coord.queue('/v1/releases/qualification', (200, {'status': 'pending'}))
        clock = iter(range(0, 10 ** 6, 600))
        with patch.object(PUB.time, 'monotonic', side_effect=lambda: next(clock)), \
                patch.object(PUB.time, 'sleep'):
            with self.assertRaises(PUB.QualificationTimeout):
                run_main(['await', '--directory', str(self.root)], dict(self.env, QUALIFICATION_WAIT_MINUTES='600'))
        polls = self.coord.paths_called().count('/v1/releases/qualification')
        self.assertLessEqual(polls, PUB.MAX_WAIT_MINUTES * 60 // 600 + 2)

    def test_summary_names_the_source_run_on_resume(self):
        summary = self.base / 'summary.md'
        run_main(['summary', '--directory', str(self.root)],
                 dict(self.env, GITHUB_RUN_ID='999', GITHUB_RUN_ATTEMPT='1', SOURCE_RUN_ID='123',
                      SOURCE_SHA='d' * 40, GITHUB_STEP_SUMMARY=str(summary)))
        text = summary.read_text()
        self.assertIn('actions/runs/123', text)
        self.assertNotIn('actions/runs/999', text)


if __name__ == '__main__':
    unittest.main()
