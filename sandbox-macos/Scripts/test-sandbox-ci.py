#!/usr/bin/env python3
"""Offline CI bundle/evidence tests; never calls a consumer API."""
import copy
import hashlib
import io
import json
import os
from pathlib import Path
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch

from sandbox_ci_bundle import digest, inventory_digest, pack_tree, remove_private_tree, seed_download_cache, unpack_tracked_snapshot, validate_output_location
from sandbox_ci_evidence import summarize, validate_sample, verify_evidence_archive
from sandbox_ci_remote import Remote, validate_nonproduction_url
from sandbox_ci_capture import capture, failed


class CIBundleTests(unittest.TestCase):
    def test_output_cannot_overlap_source_sdk_or_existing_cache(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            inputs = [root / name for name in ('repo', 'sdk', 'module-cache')]
            for value in inputs:
                value.mkdir()
            validate_output_location(root / 'new-evidence', *inputs)
            for value in inputs:
                with self.assertRaises(ValueError):
                    validate_output_location(value / 'benchmark-output', *inputs)
            alias = root / 'sdk-alias'
            alias.symlink_to(inputs[1])
            with self.assertRaises(ValueError):
                validate_output_location(alias / 'benchmark-output', *inputs)

    def test_archives_are_reproducible_and_keep_executable_identity(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / 'source'
            source.mkdir()
            (source / 'runner').write_bytes(b'fixed binary')
            (source / 'runner').chmod(0o700)
            first = pack_tree(source, root / 'one.tar.gz', 'source')
            second = pack_tree(source, root / 'two.tar.gz', 'source')
            self.assertEqual(digest(root / 'one.tar.gz'), digest(root / 'two.tar.gz'))
            self.assertEqual(inventory_digest(first), inventory_digest(second))
            self.assertTrue(first[0]['executable'])
            (source / 'runner').chmod(0o600)
            third = pack_tree(source, root / 'three.tar.gz', 'source')
            self.assertNotEqual(inventory_digest(first), inventory_digest(third))
            (source / 'link').symlink_to(root / 'outside')
            with self.assertRaises(ValueError):
                pack_tree(source, root / 'unsafe.tar.gz', 'source')

    def test_snapshot_rejects_traversal_and_links(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for index, name in enumerate(('../escape', '/absolute', 'link')):
                archive = root / f'{index}.tar'
                with tarfile.open(archive, 'w') as output:
                    header = tarfile.TarInfo(name)
                    header.type = tarfile.SYMTYPE if name == 'link' else tarfile.REGTYPE
                    header.linkname = '../outside'
                    output.addfile(header, io.BytesIO())
                with self.assertRaises(ValueError):
                    unpack_tracked_snapshot(archive, root / f'dest-{index}')

    def test_private_cache_copy_and_cleanup_do_not_modify_selected_cache(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            selected = root / 'user-cache'
            version = selected / 'cache/download/example.test/module/@v'
            version.mkdir(parents=True)
            (version / 'v1.0.0.mod').write_bytes(b'module example.test/module\n')
            (version / 'v1.0.0.zip').write_bytes(b'opaque pinned archive')
            before = {path.name: (path.read_bytes(), path.stat().st_mtime_ns) for path in version.iterdir()}
            private = root / 'private-cache'
            seed_download_cache(selected, private, [{'Path': 'example.test/module', 'Version': 'v1.0.0'}])
            private.chmod(0o500)
            (private / 'cache/download/example.test/module').chmod(0o500)
            remove_private_tree(private)
            self.assertFalse(private.exists())
            self.assertEqual(before, {path.name: (path.read_bytes(), path.stat().st_mtime_ns) for path in version.iterdir()})

    def test_only_explicit_nonproduction_origins_are_allowed(self):
        for url in ('https://api.darkbloom.dev', 'https://API.DARKBLOOM.DEV.', 'https://key:secret@example.test',
                    'https://example.test/path', 'http://example.test', 'https://example.test?key=secret'):
            with self.assertRaises(ValueError):
                validate_nonproduction_url(url, True)
        self.assertEqual(validate_nonproduction_url('https://ci.example.test', False), 'https://ci.example.test')
        self.assertEqual(validate_nonproduction_url('http://127.0.0.1:8080', True), 'http://127.0.0.1:8080')
        with self.assertRaises(ValueError):
            validate_nonproduction_url('http://127.0.0.1:8080', False)


class CIEvidenceTests(unittest.TestCase):
    def sample(self):
        return {'schema_version': 1, 'workload': 'darkbloom_sandbox_ci_v1', 'status': 'passed', 'manifest_sha256': 'a'*64,
                'run_id': 'b'*32, 'go_version': 'go1.25.4', 'goos': 'darwin', 'goarch': 'arm64', 'gomaxprocs': 4, 'fresh_gocache': True,
                'build_seconds': 2.0, 'test_seconds': 1.0, 'inner_seconds': 3.0, 'caller_wall_seconds': 8.0,
                'artifacts_sha256': {name: hashlib.sha256(name.encode()).hexdigest() for name in ('probe', 'tests-0', 'tests-1', 'tests-2')},
                'tests': [{'package': './coordinator/' + name, 'passed': 2, 'skipped': 0, 'package_passed': True}
                          for name in ('protocol', 'sandboxhost', 'sandboxcontrol')], 'evidence_sha256': 'c'*64}

    def manifest(self):
        return {key: self.sample()[key] for key in ('go_version', 'goos', 'goarch', 'gomaxprocs')}

    def test_bad_identity_timing_or_skipped_work_cannot_be_a_measurement(self):
        sample = self.sample()
        validate_sample(sample, 'a'*64, self.manifest())
        for key, value in [('fresh_gocache', 1), ('schema_version', True), ('build_seconds', float('nan')),
                           ('test_seconds', 0), ('inner_seconds', 9), ('manifest_sha256', 'd'*64), ('artifacts_sha256', {})]:
            with self.assertRaises(ValueError):
                validate_sample({**sample, key: value}, 'a'*64, self.manifest())
        changed = copy.deepcopy(sample)
        changed['tests'][0]['skipped'] = 1
        with self.assertRaises(ValueError):
            validate_sample(changed, 'a'*64, self.manifest())

    def test_compiled_outputs_and_case_counts_must_match_pairs(self):
        host, guest = self.sample(), self.sample()
        guest.update(build_seconds=4, test_seconds=2, inner_seconds=6, caller_wall_seconds=20)
        summary = summarize([{'host': host, 'guest': guest}])
        self.assertEqual(summary['median_guest_over_host']['inner_seconds'], 2)
        self.assertEqual(summary['median_guest_api_wall_seconds'], 20)
        guest['artifacts_sha256']['probe'] = '0'*64
        with self.assertRaises(ValueError):
            summarize([{'host': host, 'guest': guest}])

    def test_downloaded_artifacts_are_independently_verified(self):
        with tempfile.TemporaryDirectory() as directory:
            sample = self.sample()
            for corrupt in (False, True):
                archive = Path(directory) / f'{corrupt}.tar.gz'
                with tarfile.open(archive, 'w:gz') as output:
                    members = {'sample.json': json.dumps(sample).encode()}
                    members.update({name: name.encode() for name in sample['artifacts_sha256']})
                    if corrupt:
                        members['probe'] = b'changed binary'
                    for name, data in members.items():
                        header = tarfile.TarInfo(name)
                        header.size = len(data)
                        output.addfile(header, io.BytesIO(data))
                if corrupt:
                    with self.assertRaises(ValueError):
                        verify_evidence_archive(archive, sample)
                else:
                    verify_evidence_archive(archive, sample)


class CICaptureTests(unittest.TestCase):
    def test_output_is_bounded_and_overflow_is_failure(self):
        result = capture([sys.executable, '-c', "import os; os.write(1,b'x'*200000)"], limit=1024, timeout=5)
        self.assertEqual(len(result['stdout']), 1024)
        self.assertTrue(result['capture_truncated'])
        self.assertTrue(failed(result))

    def test_timeout_keeps_partial_output(self):
        result = capture([sys.executable, '-c', "import time; print('started',flush=True); time.sleep(30)"], timeout=1)
        self.assertTrue(result['interrupted'])
        self.assertIn(b'started', result['stdout'])
        self.assertTrue(failed(result))

    def fake_cli(self, root, body):
        program = root / 'fake-cli'
        program.write_text('#!' + sys.executable + '\n' + body)
        program.chmod(0o700)
        return program

    def test_remote_capture_redacts_escaped_secret_and_preserves_raw_nonsecret_output(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            cli = self.fake_cli(root, "import json,os\nprint(json.dumps({'echo':os.environ['DARKBLOOM_API_KEY']}))\n")
            output = root / 'evidence'
            output.mkdir()
            secret = 'private"key'
            with patch.dict(os.environ, {'DARKBLOOM_API_KEY': secret}):
                remote = Remote(cli, 'https://ci.example.test', '00000000-0000-0000-0000-000000000001', output, False)
                remote.call(['inspect', secret])
            record = json.loads((output / 'cli-0001.json').read_text())
            self.assertNotIn(secret, json.dumps(record))
            self.assertNotIn('private', record['stdout'])
            self.assertEqual(record['argv'][1], '[REDACTED]')
            self.assertEqual((output / 'cli-0001.json').stat().st_mode & 0o777, 0o600)
            from sandbox_ci_remote import safe_output
            raw = b'{"okay":true, "spacing":  12}\n'
            self.assertEqual(safe_output(raw, secret), raw.decode())

    def test_remote_timeout_records_partial_evidence_before_error(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            cli = self.fake_cli(root, "import time\nprint('started',flush=True)\ntime.sleep(30)\n")
            output = root / 'evidence'
            output.mkdir()
            with patch.dict(os.environ, {'DARKBLOOM_API_KEY': 'private-key'}):
                remote = Remote(cli, 'https://ci.example.test', '00000000-0000-0000-0000-000000000001', output, False)
                with self.assertRaises(RuntimeError):
                    remote.call(['inspect'], timeout=1)
            record = json.loads((output / 'cli-0001.json').read_text())
            self.assertTrue(record['interrupted'])
            self.assertIn('started', record['stdout'])


if __name__ == '__main__':
    unittest.main()
