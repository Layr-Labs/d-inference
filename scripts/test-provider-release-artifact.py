#!/usr/bin/env python3
"""Offline exact-artifact identity, provenance and download regressions."""
import hashlib
import json
from pathlib import Path
import stat
import tempfile
import unittest
from unittest.mock import patch
import zipfile

import provider_release_artifact as artifact


class ArtifactTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        (self.root / artifact.BUNDLE).write_bytes(b'exact signed bytes')
        self.payload = {'source_commit': 'd'*40, 'ci_run_id': '123',
                        'bundle_hash': artifact.sha256(self.root / artifact.BUNDLE)}
        self.provenance = {'source_commit': 'd'*40, 'signing_workflow_commit': 'e'*40,
                           'signing_run_id': '123', 'signing_run_attempt': '2',
                           'build_run_id': '122', 'build_run_attempt': '1',
                           'unsigned_artifact_id': '99', 'unsigned_artifact_digest': 'sha256:'+'f'*64}
        (self.root / 'release-payload.json').write_text(json.dumps(self.payload))
        (self.root / 'release-provenance.json').write_text(json.dumps(self.provenance))
        self.payload_digest = artifact.sha256(self.root / 'release-payload.json')
        self.provenance_digest = artifact.sha256(self.root / 'release-provenance.json')

    def checked_payload(self, source='d'*40, run='123'):
        return artifact.checked_payload(self.root, self.payload_digest, self.provenance_digest, source, run)

    def test_exact_artifact_preserves_original_signing_attempt_and_provenance(self):
        before = (self.root / 'release-provenance.json').read_bytes()
        self.assertEqual(self.checked_payload(), self.payload)
        self.assertEqual((self.root / 'release-provenance.json').read_bytes(), before)
        self.assertEqual(self.provenance['signing_run_attempt'], '2')

    def test_modified_metadata_or_bundle_fails(self):
        for name in ('release-payload.json', 'release-provenance.json', artifact.BUNDLE):
            with self.subTest(name=name):
                path = self.root / name
                original = path.read_bytes()
                path.write_bytes(original + b' ')
                with self.assertRaisesRegex(ValueError, 'digest mismatch'):
                    self.checked_payload()
                path.write_bytes(original)

    def test_source_and_run_substitution_fail(self):
        for source, run in [('a'*40, '123'), ('d'*40, '124')]:
            with self.assertRaisesRegex(ValueError, 'source/signing run'):
                self.checked_payload(source, run)

    def test_provenance_must_agree_even_when_its_digest_matches(self):
        for field, value in [('source_commit', 'a'*40), ('signing_run_id', '124')]:
            (self.root / 'release-provenance.json').write_text(json.dumps(dict(self.provenance, **{field: value})))
            self.provenance_digest = artifact.sha256(self.root / 'release-provenance.json')
            with self.assertRaisesRegex(ValueError, 'source/signing run'):
                self.checked_payload()

    def test_symlinked_metadata_or_bundle_is_rejected(self):
        for name in ('release-payload.json', 'release-provenance.json', artifact.BUNDLE):
            with self.subTest(name=name):
                path = self.root / name
                original = path.read_bytes()
                target = self.root / 'target'
                target.write_bytes(original)
                path.unlink()
                path.symlink_to(target)
                with self.assertRaisesRegex(ValueError, 'digest mismatch'):
                    self.checked_payload()
                path.unlink()
                path.write_bytes(original)

    def zip_artifact(self, names=('release-payload.json',), mode=None):
        archive = self.root / 'artifact.zip'
        with zipfile.ZipFile(archive, 'w') as target:
            for name in names:
                member = zipfile.ZipInfo(name)
                if mode is not None:
                    member.external_attr = mode << 16
                target.writestr(member, b'{}')
        raw = archive.read_bytes()
        digest = hashlib.sha256(raw).hexdigest()
        metadata = {'id': 99, 'digest': 'sha256:' + digest, 'expired': False,
                    'size_in_bytes': len(raw), 'workflow_run': {'id': 123}}
        return raw, digest, metadata

    def download(self, raw, digest, metadata):
        def copy_zip(args, stdout, **kwargs):
            stdout.write(raw)
        with patch.object(artifact.subprocess, 'check_output', return_value=json.dumps(metadata).encode()), \
                patch.object(artifact.subprocess, 'run', side_effect=copy_zip):
            artifact.download('Layr-Labs/d-inference', '99', digest, '123', self.root / 'download')

    def test_exact_id_run_and_transport_digest_download(self):
        self.download(*self.zip_artifact())
        self.assertEqual((self.root / 'download/release-payload.json').read_bytes(), b'{}')

    def test_wrong_run_identity_expiry_size_or_digest_blocks_download(self):
        _, digest, metadata = self.zip_artifact()
        for changed in [dict(id=100), dict(workflow_run={'id': 124}), dict(expired=True),
                        dict(size_in_bytes=0), dict(size_in_bytes=(2 << 30) + 1), dict(digest='sha256:'+'0'*64)]:
            with self.subTest(changed=changed), \
                    patch.object(artifact.subprocess, 'check_output', return_value=json.dumps(dict(metadata, **changed)).encode()), \
                    patch.object(artifact.subprocess, 'run') as fetch:
                with self.assertRaises(ValueError):
                    artifact.download('Layr-Labs/d-inference', '99', digest, '123', self.root / 'download')
                fetch.assert_not_called()

    def test_substituted_zip_fails_before_extraction(self):
        raw, digest, metadata = self.zip_artifact()
        with self.assertRaisesRegex(ValueError, 'transport digest'):
            self.download(raw + b'tampered', digest, metadata)
        self.assertFalse((self.root / 'download').exists())

    def test_unsafe_paths_duplicates_and_symlinks_fail_before_extraction(self):
        for names, mode in [(('../escape',), None), (('/absolute',), None), (('a\\b',), None),
                            (('a', 'A'), None), (('link',), stat.S_IFLNK | 0o777)]:
            with self.subTest(names=names), self.assertRaisesRegex(ValueError, 'Unsafe Actions artifact path'):
                self.download(*self.zip_artifact(names, mode))
            self.assertFalse((self.root / 'download').exists())


if __name__ == '__main__':
    unittest.main()
