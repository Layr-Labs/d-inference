#!/usr/bin/env python3
"""Offline regression tests for exact-artifact qualification boundaries."""
import base64
import copy
from datetime import datetime, timedelta, timezone
import hashlib
import io
import json
from pathlib import Path
import plistlib
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import time
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import zipfile

from provider_release_qualification import contract, download, isolation, macos, receipt


class Fixture(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.bundle = self.root / contract.BUNDLE
        self.bundle.write_bytes(b'exact signed bytes')
        self.payload = {
            'version': '0.9.8', 'platform': 'macos-arm64', 'backend': 'mlx-swift',
            'binary_hash': 'a' * 64, 'bundle_hash': contract.sha256(self.bundle),
            'metallib_hash': 'b' * 64, 'code_directory_hash': 'c' * 64,
            'source_commit': 'd' * 40, 'ci_run_id': '123',
            'require_app_attest_qualification': True, 'changelog': 'Fixture',
        }
        self.payload['url'] = f"https://releases.example/releases/v0.9.8/artifacts/{self.payload['bundle_hash']}/{contract.BUNDLE}"
        self.provenance = {
            'source_commit': 'd' * 40, 'signing_workflow_commit': 'e' * 40,
            'signing_run_id': '123', 'signing_run_attempt': '2', 'build_run_id': '122',
            'build_run_attempt': '1', 'unsigned_artifact_id': '', 'unsigned_artifact_digest': '',
        }
        (self.root / 'release-payload.json').write_text(json.dumps(self.payload))
        (self.root / 'release-provenance.json').write_text(json.dumps(self.provenance))
        self.payload_digest = contract.sha256(self.root / 'release-payload.json')
        self.provenance_digest = contract.sha256(self.root / 'release-provenance.json')
        self.build = contract.build_identity(self.payload)
        self.now = datetime.now(timezone.utc).replace(microsecond=0)
        self.report = {
            'schema_version': 1, 'build': self.build, 'qualification_run_id': '456',
            'qualification_run_attempt': 3, 'policy_id': 'provider-release-v1',
            'issued_at': (self.now - timedelta(minutes=1)).isoformat(),
            'expires_at': (self.now + timedelta(minutes=59)).isoformat(),
            'checks': [{'name': name, 'status': 'passed', 'evidence_sha256': 'f' * 64}
                       for name in sorted(contract.CHECKS)],
        }

    def candidate(self):
        return contract.candidate(self.root, self.payload_digest, self.provenance_digest, 'd' * 40, '123')

    def validate(self, report=None):
        contract.validate_receipt(report or self.report, self.build, 'provider-release-v1', '456', 3, self.now)


class ContractTests(Fixture):
    def test_exact_candidate_preserves_original_signing_attempt(self):
        payload, build = self.candidate()
        self.assertEqual(payload, self.payload)
        self.assertEqual(build, self.build)
        self.assertEqual(self.provenance['signing_run_attempt'], '2')

    def test_modified_metadata_or_bundle_fails(self):
        for name in ('release-payload.json', 'release-provenance.json', contract.BUNDLE):
            with self.subTest(name=name):
                path = self.root / name
                original = path.read_bytes()
                path.write_bytes(original + b' ')
                with self.assertRaisesRegex(ValueError, 'digest mismatch'):
                    self.candidate()
                path.write_bytes(original)

    def test_source_and_run_substitution_fail(self):
        for source, run in [('a' * 40, '123'), ('d' * 40, '124')]:
            with self.assertRaisesRegex(ValueError, 'source/signing run'):
                contract.candidate(self.root, self.payload_digest, self.provenance_digest, source, run)

    def test_duplicate_nonfinite_and_oversize_json_fail(self):
        for data in (b'{"build":1,"build":2}', b'{"value":NaN}', b' ' * (contract.MAX_JSON_BYTES + 1)):
            with self.assertRaises(ValueError):
                contract.strict_json(data)

    def test_exact_check_set_and_fresh_receipt_pass(self):
        self.validate()

    def test_no_missing_duplicate_unknown_or_not_run_check(self):
        mutations = [lambda x: x.pop(), lambda x: x.append(x[0]),
                     lambda x: x[0].update(name='unknown'), lambda x: x[0].update(status='NOT RUN'),
                     lambda x: x[0].update(status='failed'), lambda x: x[0].update(evidence_sha256=''),
                     lambda x: x[0].update(exception='approved')]
        for mutate in mutations:
            report = copy.deepcopy(self.report)
            mutate(report['checks'])
            with self.assertRaises(ValueError):
                self.validate(report)

    def test_no_receipt_fields_identity_or_type_substitution(self):
        for key, value in [('schema_version', True), ('schema_version', 2), ('extra', 'field'),
                           ('qualification_run_attempt', True), ('qualification_run_attempt', 4),
                           ('qualification_run_id', '457'), ('policy_id', 'other')]:
            with self.assertRaises(ValueError):
                self.validate(dict(self.report, **{key: value}))
        for key in ('code_directory_hash', 'source_commit', 'ci_run_id'):
            report = copy.deepcopy(self.report)
            report['build'][key] = {'code_directory_hash': 'e' * 64, 'source_commit': 'e' * 40, 'ci_run_id': '999'}[key]
            with self.assertRaises(ValueError):
                self.validate(report)

    def test_stale_future_and_overlong_receipts_fail(self):
        for issued, expires in [(self.now, self.now), (self.now + timedelta(seconds=1), self.now + timedelta(minutes=30)),
                                (self.now - timedelta(hours=2), self.now - timedelta(hours=1)),
                                (self.now - timedelta(seconds=1), self.now + timedelta(hours=1))]:
            with self.assertRaisesRegex(ValueError, 'expired, future-issued'):
                self.validate(dict(self.report, issued_at=issued.isoformat(), expires_at=expires.isoformat()))

    def test_non_https_and_non_immutable_urls_fail(self):
        for url in ('http://releases.example/x', 'https://attacker@releases.example/x',
                    self.payload['url'] + '?override=1', self.payload['url'].replace('/artifacts/', '/latest/')):
            build = copy.deepcopy(self.build)
            build['release']['url'] = url
            with self.assertRaises(ValueError):
                contract.validate_build(build)

    def test_all_evidence_bytes_are_required(self):
        evidence = self.root / 'evidence'
        evidence.mkdir()
        raw = b'actual test output'
        digest = hashlib.sha256(raw).hexdigest()
        for check in self.report['checks']:
            check['evidence_sha256'] = digest
        (evidence / digest).write_bytes(raw)
        receipt.verify_evidence(self.report, evidence)
        (evidence / digest).write_bytes(b'changed')
        with self.assertRaisesRegex(ValueError, 'evidence digest mismatch'):
            receipt.verify_evidence(self.report, evidence)

    def test_real_detached_ed25519_signature_and_tamper(self):
        key = self.root / 'private.pem'
        public = self.root / 'public.der'
        raw = self.root / 'receipt.json'
        signature = self.root / 'signature'
        raw.write_text(json.dumps(self.report))
        subprocess.run(['openssl', 'genpkey', '-algorithm', 'ED25519', '-out', str(key)], check=True, capture_output=True)
        subprocess.run(['openssl', 'pkey', '-in', str(key), '-pubout', '-outform', 'DER', '-out', str(public)], check=True, capture_output=True)
        subprocess.run(['openssl', 'pkeyutl', '-sign', '-inkey', str(key), '-rawin', '-in', str(raw), '-out', str(signature)], check=True, capture_output=True)
        public_key = base64.b64encode(public.read_bytes()[-32:]).decode()
        envelope = {'receipt': base64.b64encode(raw.read_bytes()).decode(), 'signature': base64.b64encode(signature.read_bytes()).decode()}
        self.assertEqual(receipt.verify(envelope, public_key, self.build, 'provider-release-v1', '456', 3, self.now), self.report)
        envelope['receipt'] = base64.b64encode(raw.read_bytes() + b' ').decode()
        with self.assertRaisesRegex(ValueError, 'signature'):
            receipt.verify(envelope, public_key, self.build, 'provider-release-v1', '456', 3, self.now)

    def test_submission_uses_release_key_not_admin_key(self):
        response = unittest.mock.MagicMock()
        response.__enter__.return_value = response
        response.status = 200
        response.read.return_value = b'{"status":"qualified"}'
        with patch.object(receipt.urllib.request, 'build_opener') as opener:
            opener.return_value.open.return_value = response
            receipt.submit({'receipt': 'x', 'signature': 'y'}, 'https://coordinator.example', 'release-secret')
            request = opener.return_value.open.call_args.args[0]
            self.assertEqual(request.full_url, 'https://coordinator.example/v1/releases/qualify')
            self.assertEqual(request.get_header('Authorization'), 'Bearer release-secret')
        with self.assertRaises(ValueError):
            receipt.NoRedirect().redirect_request(None, None, 302, '', {}, 'https://other.example')


class MacOSTests(Fixture):
    def signed_fixture(self):
        entries = {
            'bin/darkbloom': b'signed binary', 'bin/mlx.metallib': b'signed metallib',
            'Darkbloom.app/Contents/MacOS/darkbloom': b'signed binary',
            'Darkbloom.app/Contents/MacOS/mlx.metallib': b'signed metallib',
            'Darkbloom.app/Contents/Info.plist': plistlib.dumps({
                'CFBundleIdentifier': 'io.darkbloom.provider', 'CFBundleExecutable': 'darkbloom',
                'CFBundleVersion': '0.9.8', 'CFBundleShortVersionString': '0.9.8', 'LSMinimumSystemVersion': '14.0'}),
        }
        with tarfile.open(self.bundle, 'w:gz') as archive:
            for name, data in entries.items():
                member = tarfile.TarInfo(name)
                member.size = len(data)
                archive.addfile(member, io.BytesIO(data))
        self.build['release'].update(bundle_hash=contract.sha256(self.bundle),
                                     binary_hash=hashlib.sha256(b'signed binary').hexdigest(),
                                     metallib_hash=hashlib.sha256(b'signed metallib').hexdigest())
        self.entitlements = {'com.apple.developer.devicecheck.app-attest-opt-in': 'CDhash',
                             'com.apple.developer.aps-environment': 'production',
                             'keychain-access-groups': ['SLDQ2GJ6TL.io.darkbloom.provider']}
        self.profile = {'TeamIdentifier': ['SLDQ2GJ6TL'], 'Entitlements': {
            'com.apple.developer.devicecheck.app-attest-opt-in': 'CDhash'},
            'ExpirationDate': (self.now + timedelta(days=30)).replace(tzinfo=None)}
        self.real_run = subprocess.run
        self.root_commands = []
        # Captured codesign field layout, with the provider identity and runtime bit.
        self.details = ('Executable=/private/tmp/Darkbloom.app/Contents/MacOS/darkbloom\n'
                        'Identifier=io.darkbloom.provider\nFormat=app bundle with Mach-O thin (arm64)\n'
                        'CodeDirectory v=20400 size=25577 flags=0x10000(runtime) hashes=789+7 location=embedded\n'
                        'Hash type=sha256 size=32\nCandidateCDHash sha256=' + 'c' * 40 + '\n'
                        'CandidateCDHashFull sha256=' + 'c' * 64 + '\n')
        self.deployment = b'    minos 14.0\n'
        self.smoke = '\n'.join(marker + ': ok' for marker in (
            'app-attest-callback-runtime-smoke', 'gemma-optimizations-runtime-smoke',
            'paged-kernel-runtime-smoke', 'qwen4-metal-resources-runtime-smoke')).encode()

    def command_fixture(self, args, **kwargs):
        stdout, stderr = b'', b''
        if args[0] == '/usr/bin/sudo':
            self.root_commands.append((args, kwargs))
            if 'prepare' in args:
                self.isolated_root = self.root / 'isolated'
                self.isolated_root.mkdir()
                shutil.copytree(Path(args[-1]), self.isolated_root / 'Darkbloom.app')
                stdout = str(self.isolated_root).encode()
            elif 'run' in args:
                output = b'0.9.8' if args[-1] == '--version' else self.smoke
                stdout = json.dumps({'stdout': base64.b64encode(output).decode(), 'stderr': ''}).encode()
            elif 'cleanup' in args:
                shutil.rmtree(self.isolated_root)
        elif args[0] == '/usr/bin/sw_vers':
            stdout = b'26.2\n'
        elif args[0] == '/usr/bin/uname':
            stdout = b'arm64\n'
        elif args[0] == '/usr/bin/tar':
            return self.real_run(args, **kwargs)
        elif '--verbose=4' in args:
            stderr = self.details.encode()
        elif '--entitlements' in args:
            stdout = plistlib.dumps(self.entitlements)
        elif args[0] == '/usr/bin/security':
            stdout = plistlib.dumps(self.profile)
        elif 'vtool' in args:
            stdout = self.deployment
        return subprocess.CompletedProcess(args, 0, stdout, stderr)

    def test_signed_lane_writes_only_passed_exact_evidence_after_all_checks(self):
        self.signed_fixture()
        output = self.root / 'check'
        with patch.object(macos.subprocess, 'run', side_effect=self.command_fixture), \
                patch.object(isolation, 'validate_root', side_effect=lambda root: root), \
                patch.dict(isolation.os.environ, {'GH_TOKEN': 'must-not-reach-candidate', 'DYLD_INSERT_LIBRARIES': '/bad'}):
            report = macos.check_macos(self.root, self.build, output, 26, '456', 3, 'provider-release-v1')
        self.assertEqual(report['build'], self.build)
        self.assertEqual(report['qualification_run_attempt'], 3)
        self.assertEqual(report['check']['name'], 'older_macos')
        self.assertEqual(report['check']['status'], 'passed')
        evidence = output / 'evidence' / report['check']['evidence_sha256']
        self.assertEqual(contract.sha256(evidence), report['check']['evidence_sha256'])
        self.assertEqual(json.loads((output / 'report.json').read_text()), report)
        self.assertEqual(len(self.root_commands), 4)
        for args, kwargs in self.root_commands:
            self.assertEqual(args[:5], ['/usr/bin/sudo', '-n', '--', '/usr/bin/env', '-i'])
            self.assertIn('-I', args)
            self.assertEqual(kwargs['env'], {'PATH': '/usr/bin:/bin'})
        self.assertFalse(self.isolated_root.exists())

    def test_signed_lane_fails_before_report_for_identity_deployment_or_smoke_mismatch(self):
        for mutation in ('code_directory', 'runtime', 'library_validation', 'deployment', 'smoke', 'entitlement'):
            with self.subTest(mutation=mutation):
                self.signed_fixture()
                if mutation == 'code_directory':
                    self.details = self.details.replace('c' * 64, 'd' * 64)
                elif mutation == 'runtime':
                    self.details = self.details.replace('flags=0x10000(runtime)', 'flags=0x0(none)')
                elif mutation == 'library_validation':
                    # Actual non-runtime flags from /System/Library/CoreServices/Finder.app.
                    self.details = self.details.replace('flags=0x10000(runtime)', 'flags=0x2000(library-validation)')
                elif mutation == 'deployment':
                    self.deployment = b'    minos 26.0\n'
                elif mutation == 'smoke':
                    self.smoke = b'NOT RUN'
                else:
                    self.entitlements['com.apple.security.get-task-allow'] = True
                output = self.root / mutation
                with patch.object(macos.subprocess, 'run', side_effect=self.command_fixture), \
                        patch.object(isolation, 'validate_root', side_effect=lambda root: root), self.assertRaises(ValueError):
                    macos.check_macos(self.root, self.build, output, 26, '456', 3, 'provider-release-v1')
                self.assertFalse((output / 'report.json').exists())

    def test_wrong_os_cannot_generate_passing_report(self):
        output = self.root / 'check'
        with patch.object(macos.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, b'14.7\n', b'')):
            with self.assertRaisesRegex(ValueError, 'wrong macOS'):
                macos.check_macos(self.root, self.build, output, 26, '456', 3, 'provider-release-v1')
        self.assertFalse((output / 'report.json').exists())

    def test_unsafe_archive_paths_links_duplicates_and_size_fail(self):
        for names, kind in [(['../escape'], tarfile.REGTYPE), (['/absolute'], tarfile.REGTYPE),
                            (['link'], tarfile.SYMTYPE), (['a', 'A'], tarfile.REGTYPE)]:
            with tarfile.open(self.bundle, 'w:gz') as archive:
                for name in names:
                    member = tarfile.TarInfo(name)
                    member.type = kind
                    archive.addfile(member)
            with self.assertRaises(ValueError):
                macos.validate_archive(self.bundle)

    def test_regular_appledouble_archive_is_valid(self):
        with tarfile.open(self.bundle, 'w:gz') as archive:
            for name in ('./Darkbloom.app', './._Darkbloom.app'):
                member = tarfile.TarInfo(name)
                archive.addfile(member)
        macos.validate_archive(self.bundle)

    def test_developer_id_cdhash_opt_in_without_environment_is_valid(self):
        entitlements = {'com.apple.developer.devicecheck.app-attest-opt-in': ['CDhash'],
                        'keychain-access-groups': ['SLDQ2GJ6TL.io.darkbloom.provider'],
                        'com.apple.developer.aps-environment': 'production'}
        profile = {'TeamIdentifier': ['SLDQ2GJ6TL'], 'Entitlements': {
            'com.apple.developer.devicecheck.app-attest-opt-in': ['CDhash']},
            'ExpirationDate': self.now + timedelta(days=10)}
        macos.validate_entitlements(entitlements, profile)
        for mutate in (lambda e: e.update({'com.apple.security.get-task-allow': False}),
                       lambda e: e.update({'com.apple.developer.devicecheck.app-attest-opt-in': True}),
                       lambda e: e.update({'com.apple.developer.devicecheck.appattest-environment': 'development'})):
            changed = copy.deepcopy(entitlements)
            mutate(changed)
            with self.assertRaises(ValueError):
                macos.validate_entitlements(changed, profile)


class DownloadTests(Fixture):
    def artifact(self, name='report.json'):
        archive = self.root / 'artifact.zip'
        with zipfile.ZipFile(archive, 'w') as target:
            target.writestr(name, b'{}')
        raw = archive.read_bytes()
        digest = hashlib.sha256(raw).hexdigest()
        metadata = {'id': 99, 'digest': 'sha256:' + digest, 'expired': False,
                    'size_in_bytes': len(raw), 'workflow_run': {'id': 123}}
        return raw, digest, metadata

    def test_exact_id_run_and_transport_digest_download(self):
        raw, digest, metadata = self.artifact()
        def copy_zip(args, stdout, **kwargs):
            stdout.write(raw)
        with patch.object(download.subprocess, 'check_output', return_value=json.dumps(metadata).encode()), \
                patch.object(download.subprocess, 'run', side_effect=copy_zip):
            download.download('Layr-Labs/d-inference', '99', digest, '123', self.root / 'download')
        self.assertEqual((self.root / 'download/report.json').read_bytes(), b'{}')

    def test_wrong_run_metadata_blocks_zip_request(self):
        _, digest, metadata = self.artifact()
        metadata['workflow_run']['id'] = 124
        with patch.object(download.subprocess, 'check_output', return_value=json.dumps(metadata).encode()), \
                patch.object(download.subprocess, 'run') as fetch:
            with self.assertRaisesRegex(ValueError, 'originating run mismatch'):
                download.download('Layr-Labs/d-inference', '99', digest, '123', self.root / 'download')
            fetch.assert_not_called()

    def test_substituted_zip_and_path_traversal_fail(self):
        for name, tamper in [('report.json', True), ('../escape', False)]:
            raw, digest, metadata = self.artifact(name)
            def copy_zip(args, stdout, **kwargs):
                stdout.write(raw + (b'tampered' if tamper else b''))
            with patch.object(download.subprocess, 'check_output', return_value=json.dumps(metadata).encode()), \
                    patch.object(download.subprocess, 'run', side_effect=copy_zip):
                with self.assertRaises(ValueError):
                    download.download('Layr-Labs/d-inference', '99', digest, '123', self.root / 'download')
            self.assertFalse((self.root / 'download').exists())


class IsolationTests(Fixture):
    def test_policy_is_deny_default_with_only_private_home_writable(self):
        root = Path('/private/tmp/darkbloom-static-test')
        policy = isolation.sandbox_policy(root)
        self.assertIn('(deny default)', policy)
        self.assertNotIn('(allow default)', policy)
        self.assertIn('(deny network*)', policy)
        self.assertIn('(deny process-fork)', policy)
        self.assertIn('(deny process-info*)', policy)
        self.assertIn('(allow file-write* (subpath "/private/tmp/darkbloom-static-test/home") (literal "/dev/null"))', policy)
        self.assertIn('(allow process-exec (literal "/private/tmp/darkbloom-static-test/Darkbloom.app/Contents/MacOS/darkbloom"))', policy)
        self.assertNotIn('(allow file-read-metadata)', policy)
        self.assertNotIn('/Users', policy)
        self.assertNotIn('GITHUB', policy)

    def test_root_validation_rejects_other_paths_symlinks_and_writable_roots(self):
        for path in ('/private/tmp', '/tmp/darkbloom-static-a', '/private/tmp/unrelated'):
            with self.assertRaises(ValueError):
                isolation.validate_root(Path(path))
        for uid, mode in [(501, stat.S_IFDIR | 0o755), (0, stat.S_IFLNK | 0o755),
                          (0, stat.S_IFDIR | 0o777)]:
            with patch.object(Path, 'lstat', return_value=SimpleNamespace(st_uid=uid, st_mode=mode)), \
                    self.assertRaises(ValueError):
                isolation.validate_root(Path('/private/tmp/darkbloom-static-test'))

    def test_root_copy_is_immutable_strips_privilege_and_preserves_xattrs(self):
        source = self.root / 'source.app'
        source.mkdir()
        (source / 'binary').write_bytes(b'signed')
        (source / 'binary').chmod(0o6755)
        target = self.root / 'sandbox'
        target.mkdir()
        calls = []
        def ditto(args, **kwargs):
            calls.append(args)
            shutil.copytree(Path(args[-2]), Path(args[-1]))
            return subprocess.CompletedProcess(args, 0)
        def restore_permissions():
            for path in [target, *target.rglob('*')]:
                path.chmod(0o755 if path.is_dir() else 0o644)
        self.addCleanup(restore_permissions)
        with patch.object(isolation.tempfile, 'mkdtemp', return_value=str(target)), \
                patch.object(isolation.subprocess, 'run', side_effect=ditto), \
                patch.object(isolation.os, 'chown') as chown:
            self.assertEqual(isolation.prepare(source), target)
        self.assertEqual(calls[0][:3], ['/usr/bin/ditto', '--extattr', '--noacl'])
        self.assertEqual((target / 'Darkbloom.app/binary').stat().st_mode & 0o7777, 0o555)
        self.assertEqual((target / 'policy.sb').stat().st_mode & 0o777, 0o444)
        self.assertEqual((target / 'supervisor.py').stat().st_mode & 0o777, 0o400)
        self.assertEqual((target / 'home').stat().st_mode & 0o777, 0o700)
        self.assertIn(unittest.mock.call(target / 'Darkbloom.app/binary', 0, 0), chown.call_args_list)
        nobody = isolation.pwd.getpwnam('nobody')
        self.assertIn(unittest.mock.call(target / 'home', nobody.pw_uid, nobody.pw_gid), chown.call_args_list)

    def supervised_child(self, code, limit=None):
        app = self.root / 'Darkbloom.app'
        app.mkdir(exist_ok=True)
        (self.root / 'home').mkdir(exist_ok=True)
        real_popen = subprocess.Popen
        children = []
        def spawn(args, **kwargs):
            self.assertEqual(args[0], '/usr/bin/sandbox-exec')
            self.assertEqual(args[-1], 'runtime-smoke')
            self.assertEqual(kwargs['env']['USER'], 'nobody')
            self.assertEqual(kwargs['env']['HOME'], str(self.root / 'home'))
            self.assertNotIn('GH_TOKEN', kwargs['env'])
            self.assertNotIn('GITHUB_ENV', kwargs['env'])
            self.assertTrue(kwargs['start_new_session'])
            with patch.object(isolation.os, 'setgroups') as groups, \
                    patch.object(isolation.os, 'setgid') as gid, \
                    patch.object(isolation.os, 'setuid') as uid, \
                    patch.object(isolation.resource, 'setrlimit') as limits:
                kwargs.pop('preexec_fn')()
                groups.assert_called_once_with([])
                gid.assert_called_once_with(isolation.pwd.getpwnam('nobody').pw_gid)
                uid.assert_called_once_with(isolation.pwd.getpwnam('nobody').pw_uid)
                self.assertIn(unittest.mock.call(isolation.resource.RLIMIT_NPROC, (1, 1)), limits.call_args_list)
            child = real_popen([sys.executable, '-c', code], **kwargs)
            children.append(child)
            return child
        with patch.object(isolation, 'validate_root', return_value=self.root), \
                patch.object(Path, 'lstat', return_value=SimpleNamespace(st_uid=0, st_mode=stat.S_IFREG | 0o444)), \
                patch.object(isolation.subprocess, 'Popen', side_effect=spawn), \
                patch.object(isolation, 'COMMAND_TIMEOUT', limit or 5), \
                patch.dict(isolation.os.environ, {'GH_TOKEN': 'secret', 'GITHUB_ENV': '/actions/env'}):
            try:
                return isolation.supervise(self.root, 'runtime-smoke')
            finally:
                for child in children:
                    self.assertIsNotNone(child.poll(), 'Supervisor left its child running')

    def test_supervisor_drops_identity_and_captures_bounded_output(self):
        result = self.supervised_child("print('runtime-smoke: ok')")
        self.assertEqual(base64.b64decode(result['stdout']), b'runtime-smoke: ok\n')

    def test_supervisor_kills_only_its_child_group_on_timeout_or_overflow(self):
        started = time.monotonic()
        with self.assertRaises(TimeoutError):
            self.supervised_child('import time; time.sleep(10)', limit=0.05)
        self.assertLess(time.monotonic() - started, 2)
        with self.assertRaisesRegex(ValueError, 'output limit'):
            self.supervised_child("import sys,time; sys.stdout.write('x' * (2 << 20)); sys.stdout.flush(); time.sleep(10)")

    def test_unsupported_sandbox_or_sudo_failure_never_falls_back(self):
        with patch.object(isolation.subprocess, 'run', side_effect=subprocess.CalledProcessError(1, ['sudo'])):
            with self.assertRaises(subprocess.CalledProcessError):
                with isolation.IsolatedCandidate(self.root):
                    self.fail('Candidate must not execute after sudo failure')
        with self.assertRaisesRegex(ValueError, 'sandbox support is mandatory'):
            self.supervised_child('raise SystemExit(71)')


if __name__ == '__main__':
    unittest.main()
