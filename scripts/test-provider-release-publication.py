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


GLM_BLOCK = (Path(__file__).resolve().parent.parent
             / 'provider-swift/Tests/ProviderCoreTests/Fixtures/ClusterRuntime/glm-5.3-flash-dev-branch17.json')
ALL_FAMILIES = ['hand_off', 'pipeline', 'pipeline_speculative', 'tensor_parallel']


def qualification(schedule, mode='tensor_parallel_v1', cuts=(), media=True):
    return {'schedule': schedule, 'numerics_classes': ['g17d-nax1-mlx-22222222-macos27.0'] * 2, 'cuts': list(cuts),
            'mode': mode, 'tensor_parallel_shares': None, 'promotable': True, 'diverged': False,
            'evidence_sha256': 'f' * 64, 'qualified_at': '2026-10-31T00:00:00Z',
            'request_envelope': {'sampling': True, 'tools': True, 'vision': media, 'video': media,
                                 'max_prompt_tokens': 1048576, 'max_output_tokens': 1048576}}


def cluster_runtime_block():
    """The 27B declared (a grant of its two families; the pipeline's qualifications, text only, then tensor
    parallel's), the 9B with a grant from records only, GLM with neither."""
    def model(name, seed, grant=None, qualifications=()):
        return {'model': name, 'artifact_sha256': seed * 64, 'capability_sha256': 'c' * 64, 'pair_serving_grant': grant,
                'parity_qualifications': list(qualifications), 'profile_sha256': 'd' * 64, 'resource_policy_sha256': 'e' * 64}
    declared = [qualification(1, 'pipeline_v1', [32], media=False), qualification(2, 'pipeline_v1', [32], media=False),
                qualification(1), qualification(2)]
    return {'schema': 'darkbloom_cluster_runtime_v2', 'native_runtime_sha256': '1' * 64,
            'metallib_sha256': '2' * 64, 'resource_library_sha256': '3' * 64,
            'placement_policy_sha256': '4' * 64,
            'models': [model('EigenLabs/Qwen3.8-27B-4bit-mtp', '5',
                             {'evidence_sha256': 'f' * 64, 'mode_families': ['pipeline', 'tensor_parallel']}, declared),
                       model('Qwen3.5-9B', '6', {'evidence_sha256': 'a' * 64, 'mode_families': list(ALL_FAMILIES)}),
                       model('glm-5.3-flash', '7')]}


class ClusterRuntimeTests(PublicationFixture):
    # The payloads of PublicationFixture (prod) and of its dev twin, byte for
    # byte as the release lane wrote them before cluster_runtime existed: a
    # release without the block is unchanged in every environment.
    PROD_PAYLOAD_SHA256 = 'f864c569d555a574a8499160cb2a815d5d54ce2ac73294e690e16a44cf999758'
    DEV_PAYLOAD_SHA256 = 'f8d464b44d74957419bb800386735647891775bb1cfc5bc70db794033bd07e50'

    def dev_env(self):
        return dict(self.env, ENV_PREFIX='dev', VERSION='0.9.8-dev.branch.7')

    def write_block(self, block, name='cluster-runtime.json'):
        path = self.base / name
        path.write_text(block if isinstance(block, str) else json.dumps(block, sort_keys=True, separators=(',', ':')))
        return path

    def test_payload_bytes_are_unchanged_without_the_block(self):
        self.assertNotIn('cluster_runtime', self.payload)
        self.assertEqual(PUB.sha256(self.root / 'release-payload.json'), self.PROD_PAYLOAD_SHA256)
        root = self.base / 'dev'
        payload = PUB.prepare(root, self.root / PUB.BUNDLE, self.dev_env())
        self.assertNotIn('cluster_runtime', payload)
        self.assertEqual(PUB.sha256(root / 'release-payload.json'), self.DEV_PAYLOAD_SHA256)

    def test_every_environment_carries_a_valid_block_through_stage(self):
        # Staging is refused before and after this block ("Unknown publication environment").
        for env in (self.dev_env(), dict(self.env, VERSION='0.9.9')):
            with self.subTest(environment=env['ENV_PREFIX']):
                block, root = cluster_runtime_block(), self.base / env['ENV_PREFIX']
                payload = PUB.prepare(root, self.root / PUB.BUNDLE, env, self.write_block(block))
                self.assertEqual(payload['cluster_runtime'], block)
                self.assertEqual(list(payload)[-1], 'cluster_runtime')
                written = json.loads((root / 'release-payload.json').read_text())
                self.assertEqual(written['cluster_runtime'], block)
                # Every other field is the payload without the block.
                without = PUB.prepare(self.base / (env['ENV_PREFIX'] + '-without'), self.root / PUB.BUNDLE, env)
                self.assertEqual({key: value for key, value in written.items() if key != 'cluster_runtime'}, without)
                env.update(RELEASE_PAYLOAD_SHA256=PUB.sha256(root / 'release-payload.json'),
                           RELEASE_PROVENANCE_SHA256=PUB.sha256(root / 'release-provenance.json'))
                with patch.object(PUB, 'upload') as upload:
                    PUB.stage(root, env)
                upload.assert_called_once()
        with self.assertRaisesRegex(ValueError, 'Unknown publication environment'):
            PUB.prepare(self.base / 'staging', self.root / PUB.BUNDLE, dict(self.env, ENV_PREFIX='staging'),
                        self.write_block(cluster_runtime_block()))

    def test_registration_sends_the_block_in_its_canonical_form(self):
        def sent(env, payload):
            with patch.object(PUB.urllib.request, 'build_opener') as opener:
                opener.return_value.open.return_value.__enter__.return_value.read.return_value = b'{}'
                PUB.coordinator(env, '/v1/releases', payload)
                return opener.return_value.open.call_args.args[0].data
        # Read back from the retained payload, as publish does.
        root = self.base / 'dev'
        PUB.prepare(root, self.root / PUB.BUNDLE, self.dev_env(), self.write_block(cluster_runtime_block()))
        env = dict(self.dev_env(), RELEASE_PAYLOAD_SHA256=PUB.sha256(root / 'release-payload.json'),
                   RELEASE_PROVENANCE_SHA256=PUB.sha256(root / 'release-provenance.json'))
        body = sent(env, PUB.checked_payload(root, env))
        self.assertEqual(json.loads(body)['cluster_runtime'], cluster_runtime_block())
        canonical = json.dumps(cluster_runtime_block(), sort_keys=True, separators=(',', ':')).encode()
        self.assertIn(b'"cluster_runtime":' + canonical + b'}', body)
        # Without the block, the body is the one sent before cluster_runtime existed.
        self.assertEqual(sent(self.env, self.payload), json.dumps(self.payload).encode())

    def test_a_block_that_is_not_canonical_is_refused(self):
        block = cluster_runtime_block()
        for label, text in {'whitespace': json.dumps(block, sort_keys=True),
                            'trailing newline': json.dumps(block, sort_keys=True, separators=(',', ':')) + '\n',
                            'unsorted keys': json.dumps(dict(reversed(list(block.items()))), separators=(',', ':'))}.items():
            with self.subTest(row=label), self.assertRaisesRegex(ValueError, 'not canonical'):
                PUB.prepare(self.base / label, self.root / PUB.BUNDLE, self.dev_env(), self.write_block(text))
            self.assertFalse((self.base / label).exists())

    def test_malformed_block_is_refused(self):
        def edited(change):
            block = cluster_runtime_block()
            change(block)
            return block
        many = [dict(cluster_runtime_block()['models'][1], model=f'model-{index:02d}') for index in range(65)]
        def edited_q(change, index=0):
            return edited(lambda b: change(b['models'][0]['parity_qualifications'][index]))

        def edited_envelope(change):
            return edited_q(lambda q: change(q['request_envelope']))

        def edited_grant(change):
            return edited(lambda b: change(b['models'][0]['pair_serving_grant']))
        rows = {
            'unknown field': edited(lambda b: b.update(extra='x')),
            'missing field': edited(lambda b: b.pop('metallib_sha256')),
            'schema v1': edited(lambda b: b.update(schema='darkbloom_cluster_runtime_v1')),
            'unknown model field': edited(lambda b: b['models'][0].update(extra='x')),
            'missing model field': edited(lambda b: b['models'][0].pop('profile_sha256')),
            'no pair_serving_grant': edited(lambda b: b['models'][2].pop('pair_serving_grant')),
            'grant a string': edited(lambda b: b['models'][2].update(pair_serving_grant='pipeline')),
            'grant a list': edited(lambda b: b['models'][2].update(pair_serving_grant=['pipeline'])),
            'grant empty': edited(lambda b: b['models'][2].update(pair_serving_grant={})),
            'unknown grant field': edited_grant(lambda g: g.update(granted_at='2026-10-31T00:00:00Z')),
            'missing grant field': edited_grant(lambda g: g.pop('mode_families')),
            'families not a list': edited_grant(lambda g: g.update(mode_families='pipeline')),
            'no mode family': edited_grant(lambda g: g.update(mode_families=[])),
            'unknown mode family': edited_grant(lambda g: g.update(mode_families=['pipeline_mtp'])),
            'mode families unsorted': edited_grant(lambda g: g.update(mode_families=['tensor_parallel', 'pipeline'])),
            'mode family repeated': edited_grant(lambda g: g.update(mode_families=['pipeline', 'pipeline'])),
            'family not a string': edited_grant(lambda g: g.update(mode_families=[1])),
            'zero grant evidence': edited_grant(lambda g: g.update(evidence_sha256='0' * 64)),
            'uppercase grant evidence': edited_grant(lambda g: g.update(evidence_sha256='F' * 64)),
            'grant evidence not a string': edited_grant(lambda g: g.update(evidence_sha256=7)),
            'no parity_qualifications': edited(lambda b: b['models'][1].pop('parity_qualifications')),
            'qualifications null': edited(lambda b: b['models'][1].update(parity_qualifications=None)),
            'qualification a string': edited(lambda b: b['models'][1].update(parity_qualifications=['tensor_parallel'])),
            'nine qualifications': edited(lambda b: b['models'][1].update(parity_qualifications=[
                dict(qualification(1), numerics_classes=[f'c{index}'] * 2) for index in range(9)])),
            'unknown qualification field': edited_q(lambda q: q.update(id='q1')),
            'missing qualification field': edited_q(lambda q: q.pop('qualified_at')),
            'shares absent': edited_q(lambda q: q.pop('tensor_parallel_shares')),
            'shares not null': edited_q(lambda q: q.update(tensor_parallel_shares={'version': 1, 'per_mille': [500, 500]})),
            'schedule 3': edited_q(lambda q: q.update(schedule=3)),
            'schedule true': edited_q(lambda q: q.update(schedule=True)),
            'schedule a string': edited_q(lambda q: q.update(schedule='1')),
            'unknown mode': edited_q(lambda q: q.update(mode='tensor_parallel_v9')),
            'one numerics class': edited_q(lambda q: q.update(numerics_classes=['g17d'])),
            'three numerics classes': edited_q(lambda q: q.update(numerics_classes=['a', 'b', 'c'])),
            'empty numerics class': edited_q(lambda q: q.update(numerics_classes=['', 'b'])),
            'numerics class not a string': edited_q(lambda q: q.update(numerics_classes=[1, 2])),
            'tensor parallel with a cut': edited_q(lambda q: q.update(mode='tensor_parallel_v1', cuts=[8])),
            'pipeline without a cut': edited_q(lambda q: q.update(mode='pipeline_v1', cuts=[])),
            'zero cut': edited_q(lambda q: q.update(mode='pipeline_v1', cuts=[0])),
            'cut not an integer': edited_q(lambda q: q.update(mode='pipeline_v1', cuts=[8.0])),
            'promotable a number': edited_q(lambda q: q.update(promotable=1)),
            'diverged and promotable': edited_q(lambda q: q.update(diverged=True)),
            'zero evidence': edited_q(lambda q: q.update(evidence_sha256='0' * 64)),
            'uppercase evidence': edited_q(lambda q: q.update(evidence_sha256='F' * 64)),
            'not an instant': edited_q(lambda q: q.update(qualified_at='2026-10-31')),
            'unknown envelope field': edited_envelope(lambda e: e.update(logprobs=True)),
            'missing envelope field': edited_envelope(lambda e: e.pop('video')),
            'video without vision': edited_envelope(lambda e: e.update(vision=False, video=True)),
            'no prompt tokens': edited_envelope(lambda e: e.update(max_prompt_tokens=0)),
            'too many output tokens': edited_envelope(lambda e: e.update(max_output_tokens=1048577)),
            'sampling a number': edited_envelope(lambda e: e.update(sampling=1)),
            'a placement twice': edited(lambda b: b['models'][0]['parity_qualifications'].append(qualification(1))),
            'uppercase digest': edited(lambda b: b.update(native_runtime_sha256='A' * 64)),
            'short digest': edited(lambda b: b['models'][1].update(capability_sha256='c' * 63)),
            'zero digest': edited(lambda b: b['models'][1].update(resource_policy_sha256='0' * 64)),
            'digest not a string': edited(lambda b: b.update(placement_policy_sha256=1)),
            'no models': edited(lambda b: b.update(models=[])),
            'models not a list': edited(lambda b: b.update(models={})),
            'model not an object': edited(lambda b: b['models'].append('glm')),
            'too many models': edited(lambda b: b.update(models=many)),
            'unsorted models': edited(lambda b: b['models'].reverse()),
            'repeated model': edited(lambda b: b['models'].append(dict(b['models'][-1]))),
            'empty model ID': edited(lambda b: b['models'][0].update(model='')),
            'long model ID': edited(lambda b: b['models'][0].update(model='A' * 129)),
            'non-ASCII model ID': edited(lambda b: b['models'][0].update(model='Qwené')),
            'control byte in model ID': edited(lambda b: b['models'][0].update(model='A\n')),
            'model ID not a string': edited(lambda b: b['models'][0].update(model=7)),
            'block not an object': [],
        }
        for label, block in rows.items():
            with self.subTest(row=label):
                for env in (self.dev_env(), self.env):
                    with self.assertRaisesRegex(ValueError, 'Invalid cluster_runtime'):
                        PUB.prepare(self.base / (label + env['ENV_PREFIX']), self.root / PUB.BUNDLE, env,
                                    self.write_block(block))
                    self.assertFalse((self.base / (label + env['ENV_PREFIX'])).exists())
                with self.assertRaisesRegex(ValueError, 'Invalid cluster_runtime'):
                    PUB.check_cluster_runtime(block)
                with self.assertRaisesRegex(ValueError, 'Invalid cluster_runtime'):
                    PUB.validate(dict(self.payload, cluster_runtime=block), self.env)
        text = json.dumps(cluster_runtime_block())
        for label, data in {'repeated field': text[:-1] + ', "schema": "darkbloom_cluster_runtime_v2"}',
                            'repeated grant field': text.replace('"evidence_sha256"', '"mode_families": [], "evidence_sha256"', 1),
                            'repeated qualification field': text.replace('"cuts"', '"schedule": 1, "cuts"', 1),
                            'over its bound': text + ' ' * (64 * 1024), 'not JSON': text[:-1]}.items():
            with self.subTest(row=label), self.assertRaisesRegex(ValueError, 'Invalid cluster_runtime'):
                PUB.prepare(self.base / label, self.root / PUB.BUNDLE, self.dev_env(), self.write_block(data))

    def test_a_block_whose_derived_ids_exceed_128_bytes_is_refused_before_staging(self):
        # release/<version>/<model>/s2 with version 0.9.8-dev.branch.7: 30 bytes plus the model ID; a grant's ID
        # adds 6 more (/grant), a parity qualification's 3 (/q1, /q2).
        env = self.dev_env()
        self.assertEqual(len(f"release/{env['VERSION']}/{'m' * 98}/s2".encode()), 128)
        template = cluster_runtime_block()['models']
        refused = 'derived cluster approval, grant or parity qualification ID exceeds 128 bytes'
        for label, base, fits in (('neither', template[2], 98), ('qualifications', dict(template[0], pair_serving_grant=None), 95),
                                  ('a grant', template[1], 92), ('a grant and qualifications', template[0], 92)):
            with self.subTest(row=label):
                block, over = cluster_runtime_block(), cluster_runtime_block()
                block['models'] = [dict(base, model='m' * fits)]
                over['models'] = [dict(base, model='m' * (fits + 1))]
                payload = PUB.prepare(self.base / ('fits ' + label), self.root / PUB.BUNDLE, env,
                                      self.write_block(block, 'fits.json'))
                self.assertEqual(payload['cluster_runtime'], block)
                with self.assertRaisesRegex(ValueError, refused), patch.object(PUB, 'upload') as upload:
                    PUB.prepare(self.base / ('over ' + label), self.root / PUB.BUNDLE, env, self.write_block(over, 'over.json'))
                upload.assert_not_called()
                self.assertFalse((self.base / ('over ' + label) / 'release-payload.json').exists())
                with self.assertRaisesRegex(ValueError, refused):
                    PUB.validate(dict(payload, cluster_runtime=over), env)
        # One grant per approval; n counts each schedule's qualifications from 1 in block order: q1 the pipeline,
        # q2 tensor parallel.
        self.assertEqual(PUB.derived_ids(template[0], 'V'), [
            'release/V/EigenLabs/Qwen3.8-27B-4bit-mtp/' + suffix
            for suffix in ('s1', 's2', 's1/grant', 's2/grant', 's1/q1', 's2/q1', 's1/q2', 's2/q2')])
        self.assertEqual(PUB.derived_ids(template[2], 'V'), ['release/V/glm-5.3-flash/s1', 'release/V/glm-5.3-flash/s2'])

    def test_a_registration_body_over_the_coordinators_limit_is_refused_before_staging(self):
        # The coordinator reads POST /v1/releases under 64 KiB, the block's own bound: a block within its bound can
        # still take the body over the limit. Grow a valid block by whole qualifications, then lengthen numerics
        # classes byte by byte to a body of exactly the limit, and one byte over it.
        env, limit = self.dev_env(), PUB.COORDINATOR_REGISTRATION_MAXIMUM_BYTES
        self.assertEqual(limit, 65536)
        sized = PUB.prepare(self.base / 'sized', self.root / PUB.BUNDLE, env)
        template = cluster_runtime_block()['models'][0]

        def block(models):
            return dict(cluster_runtime_block(), models=models)

        def body(models):
            return PUB.registration_body(dict(sized, cluster_runtime=block(models)))

        def grown(models):
            count = len(models[-1]['parity_qualifications']) if models else 8
            index = len(models) - (count < 8)
            return models[:index] + [dict(template, model=f'm{index:02d}', parity_qualifications=[
                dict(qualification(1 + n % 2), numerics_classes=[f'c{n}'] * 2) for n in range(count % 8 + 1)])]

        def padded(models, extra):
            out = []
            for model in models:
                qualifications = []
                for q in model['parity_qualifications']:
                    classes = []
                    for name in q['numerics_classes']:
                        add = min(extra, 64 - len(name))
                        classes.append(name + 'x' * add)
                        extra -= add
                    qualifications.append(dict(q, numerics_classes=classes))
                out.append(dict(model, parity_qualifications=qualifications))
            self.assertEqual(extra, 0)
            return out
        models = grown([])
        while len(body(grown(models))) <= limit:
            models = grown(models)
        gap = limit - len(body(models))
        exact, over = padded(models, gap), padded(models, gap + 1)
        self.assertEqual((len(body(exact)), len(body(over))), (limit, limit + 1))
        self.assertLess(len(json.dumps(block(over), sort_keys=True, separators=(',', ':'))), PUB.CLUSTER_RUNTIME_MAXIMUM_BYTES)

        payload = PUB.prepare(self.base / 'exact', self.root / PUB.BUNDLE, env, self.write_block(block(exact), 'exact.json'))
        self.assertEqual(len(PUB.registration_body(payload)), limit)
        refused = f"registration body is {limit + 1} bytes, over the coordinator's limit of {limit} bytes"
        with self.assertRaisesRegex(ValueError, refused), patch.object(PUB, 'upload') as upload:
            PUB.prepare(self.base / 'over', self.root / PUB.BUNDLE, env, self.write_block(block(over), 'over.json'))
        upload.assert_not_called()
        self.assertFalse((self.base / 'over' / 'release-payload.json').exists())
        with self.assertRaisesRegex(ValueError, refused):
            PUB.validate(dict(payload, cluster_runtime=block(over)), env)
        # The same limit without a block: release notes the coordinator would refuse.
        with self.assertRaisesRegex(ValueError, "over the coordinator's limit"):
            PUB.validate(dict(self.payload, changelog='x' * limit), self.env)
        # Registration sends exactly the bytes that were sized.
        with patch.object(PUB.urllib.request, 'build_opener') as opener:
            opener.return_value.open.return_value.__enter__.return_value.read.return_value = b'{}'
            PUB.coordinator(dict(env, RELEASE_KEY='k'), '/v1/releases', payload)
        self.assertEqual(opener.return_value.open.call_args.args[0].data, PUB.registration_body(payload))

    def test_the_glm_block_of_the_branch17_app_is_accepted(self):
        # The block the release lane computed for GLM-5.3-Flash with the 0.10.5-dev.branch.17 app (pinned by the
        # Swift suite): canonical and valid, with the declared grant and, per schedule, the pipeline's qualification
        # (cut at 45 / 2, text only) and tensor parallel's (images and video, as DevNet's catalog lists them).
        block = PUB.load_cluster_runtime(GLM_BLOCK)
        PUB.check_cluster_derived_ids(block, '0.10.5-dev.branch.18')
        [glm] = block['models']
        self.assertEqual(glm['model'], 'glm-5.3-flash')
        self.assertEqual(glm['pair_serving_grant']['mode_families'], ['pipeline', 'tensor_parallel'])
        qualifications = glm['parity_qualifications']
        self.assertEqual([(q['schedule'], q['mode'], q['cuts']) for q in qualifications],
                         [(1, 'pipeline_v1', [22]), (2, 'pipeline_v1', [22]), (1, 'tensor_parallel_v1', []),
                          (2, 'tensor_parallel_v1', [])])
        for q in qualifications:
            self.assertEqual(q['numerics_classes'], ['g17d-nax1-mlx-98bab9d7-macos27.0'] * 2)
            self.assertEqual((q['tensor_parallel_shares'], q['promotable'], q['diverged']), (None, True, False))
            self.assertEqual(q['evidence_sha256'], glm['pair_serving_grant']['evidence_sha256'])
            media = q['mode'] == 'tensor_parallel_v1'
            self.assertEqual((q['request_envelope']['vision'], q['request_envelope']['video']), (media, media))

    def test_boundary_values_are_accepted(self):
        block = cluster_runtime_block()
        block['models'] = [dict(block['models'][1], model=f'm{index:02d}') for index in range(64)]
        PUB.check_cluster_runtime(block)
        version = '0.9.8-dev.branch.7'
        PUB.validate(dict(self.payload, version=version, require_app_attest_qualification=False,
                          url='https://releases.example/' + PUB.object_key(dict(self.payload, version=version)),
                          cluster_runtime=block), self.dev_env())
        block['models'] = [dict(block['models'][0], model=' ' + '~' * 127)]
        PUB.check_cluster_runtime(block)
        # A grant of every family; none.
        block['models'][0]['pair_serving_grant'] = {'evidence_sha256': 'f' * 64, 'mode_families': list(ALL_FAMILIES)}
        PUB.check_cluster_runtime(block)
        block['models'][0]['pair_serving_grant'] = None
        PUB.check_cluster_runtime(block)
        # Eight qualifications; a pipeline cut; a measurement kept for the record; a fraction and an offset;
        # the smallest envelope.
        block['models'][0]['parity_qualifications'] = [
            dict(qualification(1 + index % 2), numerics_classes=[f'c{index}'] * 2) for index in range(8)]
        PUB.check_cluster_runtime(block)
        block['models'][0]['parity_qualifications'] = [dict(
            qualification(1), mode='pipeline_v1', cuts=[8], promotable=False, diverged=True,
            qualified_at='2026-10-31T00:00:00.5+02:00',
            request_envelope={'sampling': False, 'tools': False, 'vision': False, 'video': False,
                              'max_prompt_tokens': 1, 'max_output_tokens': 1})]
        PUB.check_cluster_runtime(block)

    def test_only_prepare_takes_the_block(self):
        for operation in ('stage', 'publish', 'download'):
            with self.subTest(operation=operation), \
                    patch('sys.argv', ['publication', operation, '--directory', str(self.root),
                                                   '--cluster-runtime', str(self.write_block(cluster_runtime_block()))]), \
                    patch('sys.stderr'), self.assertRaises(SystemExit):
                PUB.main()


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
