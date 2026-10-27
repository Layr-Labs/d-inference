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
import urllib.error

SPEC = importlib.util.spec_from_file_location('publication', Path(__file__).with_name('provider-release-publication.py'))
PUB = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PUB)


def create_tag_repository(repo, tag, message):
    # Real local objects, but no machine-wide identity, hooks or signing tools.
    git_env = dict(os.environ, GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM='1')
    for name in ('GIT_DIR', 'GIT_WORK_TREE', 'GIT_COMMON_DIR', 'GIT_INDEX_FILE'):
        git_env.pop(name, None)
    git = ['git', '-c', 'user.name=Release Test', '-c', 'user.email=test@example.com',
           '-c', 'commit.gpgsign=false', '-c', 'tag.gpgsign=false', '-c', 'core.hooksPath=' + os.devnull]
    subprocess.run(git + ['init', '-q', str(repo)], env=git_env, check=True, capture_output=True)
    subprocess.run(git + ['commit', '--allow-empty', '-qm', 'Fixture'], cwd=repo,
                   env=git_env, check=True, capture_output=True)
    subprocess.run(git + ['tag', '-a', tag, '--cleanup=verbatim', '-F', '-'],
                   input=message.encode(), cwd=repo, env=git_env, check=True, capture_output=True)
    return dict(git_env, GIT_DIR=str(repo / '.git'), GIT_WORK_TREE=str(repo))


class ReleaseChangelog(unittest.TestCase):
    def test_original_annotation_text_is_preserved_with_and_without_signature_armor(self):
        messages = {
            'subject-and-body': 'Provider 0.9.20\n\n* Raise the cache write budget.\n* Add limits.\n',
            'opening-bullets': '* Fix A\n* Fix B\n\n\nDetails paragraph.\n',
            'multiline-paragraph': 'First line\nSecond line\nThird line\n\n\n\nDetails.\n\n\nFinal notes.\n',
            'markdown': 'Keep this code:\n```sh\nprintf "café"\n```\n\n\n# A heading\n  indented text\n',
            'inline-markers': 'Handle `-----BEGIN SSH SIGNATURE-----` safely.\n'
                              'Mention "-----BEGIN PGP SIGNATURE-----" too.\n\nKeep $(not-a-command).\n',
            'crlf': '* Fix A\r\n* Fix B\r\n\r\n\r\nDetails paragraph.\r\n',
        }
        for label, message in messages.items():
            for armor in ('', 'SSH', 'PGP'):
                with self.subTest(message=label, armor=armor), tempfile.TemporaryDirectory() as directory:
                    # Armor is fixture data, not the result of a signing operation.
                    signature = (f'-----BEGIN {armor} SIGNATURE-----\n'
                                 f'fixture-signature\n-----END {armor} SIGNATURE-----\n') if armor else ''
                    annotation = message + signature
                    tag = 'v0.9.20'
                    git_env = create_tag_repository(Path(directory) / 'repo', tag, annotation)
                    raw = subprocess.run(['git', 'cat-file', 'tag', tag], env=git_env,
                                         check=True, capture_output=True).stdout
                    self.assertEqual(raw.split(b'\n\n', 1)[1], annotation.encode())
                    with patch.dict(os.environ, git_env, clear=True):
                        self.assertEqual(PUB.release_changelog({'RELEASE_TAG': tag, 'VERSION': '0.9.20'}),
                                         message.strip())
                        self.assertEqual(PUB.release_changelog({'GITHUB_REF_TYPE': 'tag', 'GITHUB_REF_NAME': tag,
                                                               'VERSION': '0.9.20'}), message.strip())

    def test_empty_and_missing_annotations_keep_the_version_fallback(self):
        for message in ('', '-----BEGIN SSH SIGNATURE-----\nfixture\n-----END SSH SIGNATURE-----\n'):
            with self.subTest(message=message), tempfile.TemporaryDirectory() as directory:
                git_env = create_tag_repository(Path(directory) / 'repo', 'v0.9.20', message)
                with patch.dict(os.environ, git_env, clear=True):
                    for tag in ('v0.9.20', 'missing'):
                        self.assertEqual(PUB.release_changelog({'RELEASE_TAG': tag, 'VERSION': '0.9.20'}),
                                         'Release v0.9.20')


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
        self.env['RELEASE_PAYLOAD_SHA256'] = PUB.sha256(self.root / 'release-payload.json')
        self.env['RELEASE_PROVENANCE_SHA256'] = PUB.sha256(self.root / 'release-provenance.json')
        source = self.payload['source_commit']
        self.git_state = {
            'git/ref/tags/v0.9.8': {'object': {'type': 'tag', 'sha': 'e'*40}},
            'git/tags/' + 'e'*40: {'verification': {'verified': True}, 'object': {'type': 'commit', 'sha': source}},
            'commits/' + source: {'commit': {'verification': {'verified': True}}},
            'git/ref/heads/master': {'object': {'sha': source}},
            'compare/' + source + '...' + source: {'status': 'identical', 'merge_base_commit': {'sha': source}},
        }
        self.source_api = SimpleNamespace(get=lambda path: self.git_state[path])
        github = patch('provider_release_resume.api.GitHub', return_value=self.source_api)
        github.start()
        self.addCleanup(github.stop)


class PublicationTests(PublicationFixture):
    def test_resumed_signing_preserves_original_source_and_records_tooling_identity(self):
        target = self.base / 'resumed'
        env = dict(self.env, GITHUB_SHA='e'*40, GITHUB_REF_TYPE='branch', GITHUB_REF_NAME='master',
                   RELEASE_SOURCE_SHA='d'*40, RELEASE_TAG='v0.9.8', RELEASE_BUILD_RUN_ID='99',
                   RELEASE_BUILD_RUN_ATTEMPT='1', RELEASE_UNSIGNED_ARTIFACT_ID='77',
                   RELEASE_UNSIGNED_ARTIFACT_DIGEST='sha256:'+'f'*64)
        with patch.object(PUB, 'release_changelog', return_value='retained tag notes'):
            payload = PUB.prepare(target, self.root / PUB.BUNDLE, env)
        self.assertEqual(payload['source_commit'], 'd'*40)
        self.assertEqual(payload['ci_run_id'], '123')
        provenance = json.loads((target / 'release-provenance.json').read_text())
        self.assertEqual(provenance['signing_workflow_commit'], 'e'*40)
        self.assertEqual(provenance['build_run_id'], '99')
        self.assertEqual(provenance['unsigned_artifact_id'], '77')
        PUB.validate(payload, env)
        with self.assertRaisesRegex(ValueError, 'source_commit'):
            PUB.validate(payload, dict(env, RELEASE_SOURCE_SHA='c'*40))

    def test_resumed_tag_move_blocks_registration_and_aliases(self):
        env = dict(self.env, RELEASE_SOURCE_SHA='d'*40, RELEASE_TAG='v0.9.8', RELEASE_RESUME_RUN_ID='99')
        with patch('provider_release_resume.api.verify_tag', side_effect=ValueError('tag moved')), \
                patch.object(PUB, 'coordinator') as api, patch.object(PUB, 'upload') as upload:
            with self.assertRaisesRegex(ValueError, 'tag moved'):
                PUB.publish(self.root, env)
            api.assert_not_called()
            upload.assert_not_called()

    def test_tag_and_master_withdrawal_block_normal_and_resumed_publication(self):
        source = self.payload['source_commit']
        original = json.dumps(self.git_state)
        for resumed in (False, True):
            for failure in ('deleted tag', 'retargeted tag', 'invalid signature', 'unreviewed source'):
                with self.subTest(resumed=resumed, failure=failure):
                    self.git_state = json.loads(original)
                    if failure == 'deleted tag':
                        del self.git_state['git/ref/tags/v0.9.8']
                    elif failure == 'retargeted tag':
                        self.git_state['git/tags/' + 'e'*40]['object']['sha'] = 'f'*40
                    elif failure == 'invalid signature':
                        self.git_state['git/tags/' + 'e'*40]['verification']['verified'] = False
                    else:
                        self.git_state['compare/' + source + '...' + source]['status'] = 'diverged'
                    env = dict(self.env)
                    if resumed:
                        env.update(RELEASE_RESUME_RUN_ID='99', RELEASE_TAG='v0.9.8')
                    with patch.object(PUB, 'coordinator') as api, patch.object(PUB, 'upload') as upload, \
                            patch.object(PUB, 'publish_github_release') as publish:
                        with self.assertRaises((KeyError, ValueError)):
                            PUB.publish(self.root, env)
                        api.assert_not_called()
                        upload.assert_not_called()
                        publish.assert_not_called()

    def test_source_revalidation_immediately_precedes_registration(self):
        events = []
        def get(path):
            events.append(path)
            return self.git_state[path]
        def api(env, path, payload=None):
            events.append(path)
            return self.payload
        with patch.object(self.source_api, 'get', side_effect=get), \
                patch.object(PUB, 'coordinator', side_effect=api), patch.object(PUB, 'upload'), \
                patch.object(PUB, 'publish_github_release'):
            PUB.publish(self.root, self.env)
        registration = events.index('/v1/releases')
        self.assertTrue(events[registration - 1].startswith('compare/'))
        self.assertIn('git/ref/tags/v0.9.8', events[:registration])

    def test_stage_is_not_publication_or_qualification(self):
        self.assertFalse((self.root / 'qualification-request.json').exists())
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
        with patch.object(PUB, 'coordinator', side_effect=RuntimeError('revoked')), patch.object(PUB, 'upload') as upload, patch.object(PUB, 'publish_github_release') as github:
            with self.assertRaisesRegex(RuntimeError, 'revoked'):
                PUB.publish(self.root, self.env)
            upload.assert_not_called()
            github.assert_not_called()

    def test_conflict_explains_revocation_without_manual_or_hardware_approval(self):
        error = urllib.error.HTTPError('https://coordinator.example/v1/releases', 409, 'Conflict', {}, None)
        with patch.object(PUB.urllib.request, 'build_opener') as opener:
            opener.return_value.open.side_effect = error
            with self.assertRaisesRegex(RuntimeError, 'conflicting release identity or revoked artifact') as raised:
                PUB.coordinator(self.env, '/v1/releases', self.payload)
            message = str(raised.exception)
            self.assertIn('no latest aliases advanced', message)
            self.assertIn('Do not rerun signing', message)
            self.assertNotIn('qualif', message)
            self.assertNotIn('approval', message)

    def test_registration_uses_existing_release_key_and_complete_native_identity(self):
        with patch.object(PUB.urllib.request, 'build_opener') as opener:
            opener.return_value.open.return_value.__enter__.return_value.read.return_value = b'{}'
            PUB.coordinator(self.env, '/v1/releases', self.payload)
            request = opener.return_value.open.call_args.args[0]
            self.assertEqual(request.full_url, 'https://coordinator.example/v1/releases')
            self.assertEqual(request.get_header('Authorization'), 'Bearer never-log')
            sent = json.loads(request.data)
            for name in ['code_directory_hash', 'source_commit', 'ci_run_id']:
                self.assertEqual(sent[name], self.payload[name])
            self.assertIs(sent['require_app_attest_qualification'], True)

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
        marker = self.base / 'must-not-exist'
        message = ('* Restore release approvals\n* Preserve every opening line.\n\n\n'
                   'Detailed notes with "quotes", `backticks`, and $(touch ' + str(marker) + ').\n'
                   'Second paragraph: café.\n\n\nFinal paragraph.\n')
        signature = '-----BEGIN SSH SIGNATURE-----\nfixture-signature\n-----END SSH SIGNATURE-----\n'
        git_env = create_tag_repository(repo, self.env['GITHUB_REF_NAME'], message + signature)
        env = dict(self.env, GITHUB_REF_TYPE='tag')
        with patch.dict(os.environ, git_env, clear=True):
            root = self.base / 'tagged-artifact'
            payload = PUB.prepare(root, self.base / PUB.BUNDLE, env)
        self.assertEqual(payload['changelog'], message.strip())
        self.assertEqual(json.loads((root / 'release-payload.json').read_text())['changelog'], message.strip())
        self.assertEqual({key: value for key, value in payload.items() if key != 'changelog'},
                         {key: value for key, value in self.payload.items() if key != 'changelog'})
        self.assertEqual((root / PUB.BUNDLE).read_bytes(), (self.root / PUB.BUNDLE).read_bytes())
        self.assertEqual((root / 'release-provenance.json').read_bytes(),
                         (self.root / 'release-provenance.json').read_bytes())
        env.update(RELEASE_PAYLOAD_SHA256=PUB.sha256(root / 'release-payload.json'),
                   RELEASE_PROVENANCE_SHA256=PUB.sha256(root / 'release-provenance.json'))
        self.assertEqual(PUB.checked_payload(root, env), payload)
        for name in ('release-payload.json', 'release-provenance.json'):
            original = (root / name).read_bytes()
            (root / name).write_bytes(original + b'\n')
            with self.subTest(tampered=name), self.assertRaisesRegex(ValueError, 'digest mismatch'):
                PUB.checked_payload(root, env)
            (root / name).write_bytes(original)
        self.assertFalse((root / 'qualification-request.json').exists())
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
