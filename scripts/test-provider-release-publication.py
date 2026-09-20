#!/usr/bin/env python3
"""Exercise publication ordering/retries without credentials or live writes."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
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


if __name__ == '__main__':
    unittest.main()
