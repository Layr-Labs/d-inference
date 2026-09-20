#!/usr/bin/env python3
"""Exercise publication ordering/retries without credentials or live writes."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location('publication', Path(__file__).with_name('provider-release-publication.py'))
PUB = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PUB)


class PublicationTests(unittest.TestCase):
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

    def test_registration_failure_cannot_advance_aliases_or_github(self):
        with patch.object(PUB, 'coordinator', side_effect=RuntimeError('unqualified')), patch.object(PUB, 'upload') as upload, patch.object(PUB.subprocess, 'run') as run:
            with self.assertRaisesRegex(RuntimeError, 'unqualified'):
                PUB.publish(self.root, self.env)
            upload.assert_not_called()
            run.assert_not_called()

    def test_registration_and_readiness_precede_all_publication(self):
        events = []
        def api(env, path, payload=None):
            events.append(path)
            return self.payload
        def upload(root, key, env):
            events.append(key)
        with patch.object(PUB, 'coordinator', side_effect=api), patch.object(PUB, 'upload', side_effect=upload), patch.object(PUB.subprocess, 'run') as run:
            run.return_value.returncode = 1
            PUB.publish(self.root, self.env)
        self.assertEqual(events[:2], ['/v1/releases', '/v1/releases/latest?platform=macos-arm64'])
        self.assertEqual(len(events), 4)
        self.assertTrue(all('/latest/' in e for e in events[2:]))
        self.assertIn('--latest=true', run.call_args.args[0])

    def test_retry_uses_same_bytes_and_old_release_never_rolls_back_latest(self):
        before = PUB.sha256(self.root / PUB.BUNDLE)
        def api(env, path, payload=None):
            return {'version': '1.0.0', 'bundle_hash': 'f'*64}
        with patch.object(PUB, 'coordinator', side_effect=api), patch.object(PUB, 'upload') as upload, patch.object(PUB.subprocess, 'run') as run:
            def gh(args, **kwargs):
                from types import SimpleNamespace
                if args[2] == 'download':
                    (Path(args[-1]) / PUB.BUNDLE).write_bytes((self.root / PUB.BUNDLE).read_bytes())
                return SimpleNamespace(returncode=0)
            run.side_effect = gh  # GitHub release already exists with exact bytes.
            for _ in range(2):
                PUB.publish(self.root, self.env)
            upload.assert_not_called()
            self.assertEqual(run.call_count, 4)  # Verify existing asset; never replace it.
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


if __name__ == '__main__':
    unittest.main()
