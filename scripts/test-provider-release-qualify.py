#!/usr/bin/env python3
"""Exercise scripts/provider-release-qualify.py (C3) against a synthetic signed
bundle. The fixture binary is not a real Mach-O, so every external Apple tool
(codesign, xcrun stapler, vtool/otool, sw_vers, sysctl, the binary itself) is
faked through subprocess.run; only file digests and JSON structure are real.

Runnable directly: `python3 scripts/test-provider-release-qualify.py`.
If scripts/provider-release-qualify.py does not exist yet, every test below
still runs and reports an ERROR (missing module), never a silent pass/skip.
"""
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest import mock

MODULE_PATH = Path(__file__).with_name('provider-release-qualify.py')
BUNDLE_NAME = 'darkbloom-bundle-macos-arm64.tar.gz'
TEAM_ID = 'SLDQ2GJ6TL'
VERSION = '0.9.8'
SOURCE_COMMIT = 'd' * 40
CI_RUN_ID = '778899'
GOOD_CODE_DIRECTORY_HASH = 'ab' * 32
# The 4 markers grep'd by validate-older-macos, release-swift.yml:1035.
MARKERS = [
    'app-attest-callback-runtime-smoke',
    'gemma-optimizations-runtime-smoke',
    'paged-kernel-runtime-smoke',
    'qwen4-metal-resources-runtime-smoke',
]


def _load_qualify_module():
    spec = importlib.util.spec_from_file_location('provider_release_qualify', MODULE_PATH)
    if spec is None or spec.loader is None:
        raise ModuleNotFoundError(f'cannot build an import spec for {MODULE_PATH}')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


try:
    QUAL = _load_qualify_module()
    _IMPORT_ERROR = None
except Exception as exc:  # missing file, syntax error, partial stub, etc.
    QUAL = None
    _IMPORT_ERROR = exc


def sha256_bytes(data):
    return hashlib.sha256(data).hexdigest()


def write_tar(path, files):
    if path.exists():
        path.unlink()
    with tarfile.open(path, 'w:gz') as tar:
        for name in sorted(files):
            data = files[name]
            info = tarfile.TarInfo(name=name)
            info.size = len(data)
            info.mode = 0o755
            info.mtime = 0
            tar.addfile(info, io.BytesIO(data))


def build_fixture(directory, binary=None, enclave=None, metallib=None, bin_binary=None,
                   version=VERSION, source_commit=SOURCE_COMMIT, ci_run_id=CI_RUN_ID,
                   code_directory_hash=GOOD_CODE_DIRECTORY_HASH):
    """Writes a retained publication directory: the bundle tar.gz plus
    release-payload.json and qualification-request.json with digests that
    genuinely match the fixture bytes. Returns (identity, files) where
    `identity` mirrors the C3 result-JSON identity object exactly and
    `files` is the {archive member name: bytes} map used to build the tar."""
    binary = binary if binary is not None else b'DARKBLOOM-BINARY-BYTES-v1'
    enclave = enclave if enclave is not None else b'DARKBLOOM-ENCLAVE-BYTES-v1'
    metallib = metallib if metallib is not None else b'DARKBLOOM-METALLIB-BYTES-v1'
    bin_binary = bin_binary if bin_binary is not None else binary

    files = {
        'Darkbloom.app/Contents/MacOS/darkbloom': binary,
        'Darkbloom.app/Contents/MacOS/darkbloom-enclave': enclave,
        'Darkbloom.app/Contents/MacOS/mlx.metallib': metallib,
        'bin/darkbloom': bin_binary,
        'bin/darkbloom-enclave': enclave,
        'bin/mlx.metallib': metallib,
    }
    bundle_path = directory / BUNDLE_NAME
    write_tar(bundle_path, files)
    bundle_hash = sha256_bytes(bundle_path.read_bytes())

    identity = {
        'version': version,
        'binary_hash': sha256_bytes(binary),
        'bundle_hash': bundle_hash,
        'metallib_hash': sha256_bytes(metallib),
        'code_directory_hash': code_directory_hash,
        'source_commit': source_commit,
        'ci_run_id': ci_run_id,
    }

    payload = dict(identity)
    payload['platform'] = 'macos-arm64'
    payload['backend'] = 'mlx-swift'
    payload['require_app_attest_qualification'] = True
    payload['changelog'] = 'qualify-fixture'
    payload['url'] = f"https://releases.example/releases/v{version}/artifacts/{bundle_hash}/{BUNDLE_NAME}"
    (directory / 'release-payload.json').write_text(json.dumps(payload, indent=2) + '\n')

    qualification = {'code_directory_hash': code_directory_hash, 'source_commit': source_commit,
                      'ci_run_id': ci_run_id}
    qualification['release'] = {k: v for k, v in payload.items()
                                 if k not in qualification and k != 'require_app_attest_qualification'}
    qualification['evidence'] = ''
    (directory / 'qualification-request.json').write_text(json.dumps(qualification, indent=2) + '\n')

    return identity, files


def make_fake_tools(overrides=None):
    """Builds a subprocess.run replacement dispatching on argv, mirroring the
    exact commands release-swift.yml runs (:707-709, :1024, :1031-1033) plus
    the host-inspection commands (sw_vers, sysctl, vtool/otool) the validator
    must run itself since it has no CI job computing them beforehand.

    `overrides` may set plain values (code_directory_hash, team_id,
    host_version, minos, version_output, smoke_markers) or callables keyed by
    codesign_d / codesign_verify / stapler / minos_query / app_version /
    runtime_smoke that fully replace the default CompletedProcess (or raise)."""
    cfg = {
        'code_directory_hash': GOOD_CODE_DIRECTORY_HASH,
        'team_id': TEAM_ID,
        'host_version': '26.2',
        'minos': '14.0',
        'version_output': VERSION,
        'smoke_markers': list(MARKERS),
    }
    cfg.update(overrides or {})

    def call(name, argv):
        fn = cfg.get(name)
        return fn(argv) if callable(fn) else None

    def fake(argv, *args, **kwargs):
        argv = list(argv)
        head = argv[0] if argv else ''
        joined = ' '.join(argv)

        if head == 'codesign' and '-d' in argv and '--verbose=4' in argv:
            override = call('codesign_d', argv)
            if override is not None:
                return override
            stderr = ('Executable=/tmp/darkbloom\n'
                      f"CandidateCDHashFull sha256={cfg['code_directory_hash']}\n"
                      f"TeamIdentifier={cfg['team_id']}\n")
            return subprocess.CompletedProcess(argv, 0, '', stderr)

        if head == 'codesign' and '--verify' in argv:
            override = call('codesign_verify', argv)
            if override is not None:
                return override
            return subprocess.CompletedProcess(argv, 0, '', '')

        if head == 'xcrun' and 'stapler' in argv:
            override = call('stapler', argv)
            if override is not None:
                return override
            return subprocess.CompletedProcess(argv, 0, 'The validate action worked!\n', '')

        if head == 'sw_vers':
            override = call('host_version_query', argv)
            if override is not None:
                return override
            if '-buildVersion' in argv:
                return subprocess.CompletedProcess(argv, 0, '25C56\n', '')
            return subprocess.CompletedProcess(argv, 0, cfg['host_version'] + '\n', '')

        if head == 'sysctl':
            if 'hw.model' in joined:
                return subprocess.CompletedProcess(argv, 0, 'MacBookPro18,3\n', '')
            return subprocess.CompletedProcess(argv, 0, 'Apple M1 Pro\n', '')

        if head in ('vtool', 'otool'):
            override = call('minos_query', argv)
            if override is not None:
                return override
            return subprocess.CompletedProcess(argv, 0, f"minos {cfg['minos']}\n", '')

        if argv and argv[-1] == '--version':
            override = call('app_version', argv)
            if override is not None:
                return override
            return subprocess.CompletedProcess(argv, 0, cfg['version_output'] + '\n', '')

        if argv and argv[-1] == 'runtime-smoke':
            override = call('runtime_smoke', argv)
            if override is not None:
                return override
            # The real binary prints '<marker>: ok' (v0.9.8 on macOS 26.2).
            fmt = cfg.get('smoke_format', '{}: ok')
            return subprocess.CompletedProcess(argv, 0, '\n'.join(fmt.format(m) for m in cfg['smoke_markers']) + '\n', '')

        raise AssertionError('unfaked subprocess.run call, extend make_fake_tools: %r' % (argv,))

    return fake


class QualifyTestCase(unittest.TestCase):
    """Base fixture: a correct retained publication directory in a temp dir."""

    def setUp(self):
        if QUAL is None:
            raise _IMPORT_ERROR
        self.tmp = tempfile.TemporaryDirectory(prefix='provider-release-qualify-fixture-')
        self.addCleanup(self.tmp.cleanup)
        self.dir = Path(self.tmp.name)
        self.identity, self.files = build_fixture(self.dir)
        self.out = self.dir / 'qualification-result.json'

    def rebuild_bundle_with(self, files):
        """Rewrites the tar.gz from `files` and updates ONLY bundle_hash (+
        url) in release-payload.json / qualification-request.json to match
        the new bytes, leaving every other recorded digest exactly as-is so a
        single tampered file can be isolated to its own check."""
        bundle_path = self.dir / BUNDLE_NAME
        write_tar(bundle_path, files)
        new_hash = sha256_bytes(bundle_path.read_bytes())

        payload_path = self.dir / 'release-payload.json'
        payload = json.loads(payload_path.read_text())
        old_hash = payload['bundle_hash']
        payload['bundle_hash'] = new_hash
        payload['url'] = payload['url'].replace(old_hash, new_hash)
        payload_path.write_text(json.dumps(payload, indent=2) + '\n')

        q_path = self.dir / 'qualification-request.json'
        q = json.loads(q_path.read_text())
        q['release']['bundle_hash'] = new_hash
        q['release']['url'] = payload['url']
        q_path.write_text(json.dumps(q, indent=2) + '\n')
        return new_hash

    def invoke(self, lane='older-macos', level='static,smoke', fake_overrides=None, extra_argv=None):
        argv = ['provider-release-qualify.py', '--directory', str(self.dir),
                '--lane', lane, '--level', level, '--output', str(self.out)]
        if extra_argv:
            argv += list(extra_argv)
        fake = make_fake_tools(fake_overrides)
        with mock.patch.dict(os.environ, clear=False):
            os.environ.pop('DARKBLOOM_QUALIFY_LIVE', None)
            with mock.patch.object(QUAL.subprocess, 'run', side_effect=fake), \
                 mock.patch.object(sys, 'argv', argv):
                try:
                    rc = QUAL.main()
                except SystemExit as exc:
                    rc = exc.code
        return 0 if rc is None else rc

    def load_result(self):
        self.assertTrue(self.out.exists(), 'validator did not write the --output file')
        data = json.loads(self.out.read_text())
        for check in data.get('checks', []):
            self.assertIn(check.get('status'), ('passed', 'failed', 'not_run'),
                          f"check {check.get('name')!r} has an invalid status {check.get('status')!r}")
        return data

    @staticmethod
    def checks_by_name(result):
        return {c['name']: c for c in result['checks']}


class Q1StaticSmokePass(QualifyTestCase):
    def test_all_static_and_smoke_checks_pass_on_correct_host(self):
        exit_code = self.invoke(lane='older-macos', level='static,smoke')
        self.assertEqual(exit_code, 0)
        result = self.load_result()
        self.assertEqual(result['schema'], 'darkbloom.provider-qualification-result/v1')
        self.assertEqual(result['lane'], 'older-macos')
        self.assertEqual(result['levels'], ['static', 'smoke'])
        self.assertEqual(result['identity'], self.identity)
        self.assertEqual(result['host']['macos'], '26.2')
        checks = result['checks']
        self.assertTrue(checks, 'expected at least one check to run')
        for check in checks:
            self.assertIn(check['level'], ('static', 'smoke'))
            self.assertEqual(check['status'], 'passed',
                              f"{check['name']} should pass on the golden fixture: {check.get('detail')}")
        names = {c['name'] for c in checks}
        for required in ['bundle-digest', 'binary-digest', 'metallib-digest', 'code-directory',
                          'codesign', 'notarization', 'team-id', 'minimum-macos', 'lane-host',
                          'version', 'runtime-smoke']:
            self.assertIn(required, names, f'missing required check {required}')
        self.assertNotIn('live', {c['level'] for c in checks})


class Q2DigestMismatches(QualifyTestCase):
    def test_flipped_byte_in_raw_bundle_fails_bundle_digest_and_blocks_dependents(self):
        bundle_path = self.dir / BUNDLE_NAME
        data = bytearray(bundle_path.read_bytes())
        data[-1] ^= 0xFF
        bundle_path.write_bytes(bytes(data))

        exit_code = self.invoke()
        result = self.load_result()
        checks = self.checks_by_name(result)
        self.assertEqual(checks['bundle-digest']['status'], 'failed')
        for name in ['binary-digest', 'metallib-digest', 'code-directory', 'codesign',
                     'notarization', 'team-id', 'minimum-macos', 'version', 'runtime-smoke']:
            self.assertEqual(checks[name]['status'], 'not_run', f'{name} should be blocked')
            self.assertIn('bundle-digest', checks[name]['detail'])
        self.assertNotEqual(exit_code, 0)

    def test_flipped_byte_in_app_binary_fails_binary_digest_naming_it(self):
        files = dict(self.files)
        tampered = bytearray(files['Darkbloom.app/Contents/MacOS/darkbloom'])
        tampered[0] ^= 0xFF
        tampered = bytes(tampered)
        # Keep bin/darkbloom identical to the (now tampered) app copy so this
        # case isolates the hash-vs-payload mismatch, not the app/bin check.
        files['Darkbloom.app/Contents/MacOS/darkbloom'] = tampered
        files['bin/darkbloom'] = tampered
        self.rebuild_bundle_with(files)

        exit_code = self.invoke()
        result = self.load_result()
        checks = self.checks_by_name(result)
        self.assertEqual(checks['bundle-digest']['status'], 'passed')
        self.assertEqual(checks['metallib-digest']['status'], 'passed')
        self.assertEqual(checks['binary-digest']['status'], 'failed')
        self.assertIn('darkbloom', checks['binary-digest']['detail'].lower())
        self.assertNotEqual(exit_code, 0)

    def test_flipped_byte_in_metallib_fails_metallib_digest_naming_it(self):
        files = dict(self.files)
        tampered = bytearray(files['Darkbloom.app/Contents/MacOS/mlx.metallib'])
        tampered[0] ^= 0xFF
        tampered = bytes(tampered)
        files['Darkbloom.app/Contents/MacOS/mlx.metallib'] = tampered
        files['bin/mlx.metallib'] = tampered
        self.rebuild_bundle_with(files)

        exit_code = self.invoke()
        result = self.load_result()
        checks = self.checks_by_name(result)
        self.assertEqual(checks['bundle-digest']['status'], 'passed')
        self.assertEqual(checks['binary-digest']['status'], 'passed')
        self.assertEqual(checks['metallib-digest']['status'], 'failed')
        self.assertIn('metallib', checks['metallib-digest']['detail'].lower())
        self.assertNotEqual(exit_code, 0)

    def test_bin_copy_differing_from_app_copy_fails_binary_digest(self):
        files = dict(self.files)
        tampered_bin = bytearray(files['bin/darkbloom'])
        tampered_bin[0] ^= 0xFF
        files['bin/darkbloom'] = bytes(tampered_bin)
        # The app copy (and its recorded binary_hash) stay correct: this
        # isolates the byte-identical-to-bin requirement in C3's binary-digest.
        self.rebuild_bundle_with(files)

        exit_code = self.invoke()
        result = self.load_result()
        checks = self.checks_by_name(result)
        self.assertEqual(checks['bundle-digest']['status'], 'passed')
        self.assertEqual(checks['binary-digest']['status'], 'failed')
        self.assertNotEqual(exit_code, 0)


class Q3SigningChecks(QualifyTestCase):
    def test_wrong_candidate_cdhash_fails_code_directory(self):
        exit_code = self.invoke(fake_overrides={'code_directory_hash': 'ff' * 32})
        result = self.load_result()
        checks = self.checks_by_name(result)
        self.assertEqual(checks['code-directory']['status'], 'failed')
        self.assertNotEqual(exit_code, 0)

    def test_wrong_team_identifier_fails_team_id(self):
        exit_code = self.invoke(fake_overrides={'team_id': 'WRONGTEAM01'})
        result = self.load_result()
        checks = self.checks_by_name(result)
        self.assertEqual(checks['team-id']['status'], 'failed')
        self.assertNotEqual(exit_code, 0)

    def test_stapler_nonzero_exit_fails_notarization(self):
        exit_code = self.invoke(fake_overrides={
            'stapler': lambda argv: subprocess.CompletedProcess(argv, 1, '', 'No ticket found.'),
        })
        result = self.load_result()
        checks = self.checks_by_name(result)
        self.assertEqual(checks['notarization']['status'], 'failed')
        self.assertNotEqual(exit_code, 0)

    def test_codesign_verify_nonzero_exit_fails_codesign(self):
        exit_code = self.invoke(fake_overrides={
            'codesign_verify': lambda argv: subprocess.CompletedProcess(
                argv, 1, '', 'code object is not signed at all'),
        })
        result = self.load_result()
        checks = self.checks_by_name(result)
        self.assertEqual(checks['codesign']['status'], 'failed')
        self.assertNotEqual(exit_code, 0)


class AppleDoubleExtraction(QualifyTestCase):
    """The v0.9.8 archive carries `._mlx.metallib` beside `mlx.metallib`. Native
    tar drops the sidecar; writing it out breaks the app's sealed resources."""

    def test_sidecar_with_a_real_counterpart_is_not_extracted(self):
        import io
        import tarfile
        QUAL = _load_qualify_module()
        bundle = Path(self.tmp.name) / 'appledouble.tar.gz'
        with tarfile.open(bundle, 'w:gz') as tar:
            for name in ['./Darkbloom.app/Contents/MacOS/mlx.metallib', './Darkbloom.app/Contents/MacOS/._mlx.metallib',
                         './Darkbloom.app/Contents/MacOS/._orphan']:
                info = tarfile.TarInfo(name)
                info.size = 1
                tar.addfile(info, io.BytesIO(b'x'))
        dest = Path(self.tmp.name) / 'out'
        dest.mkdir()
        QUAL.safe_extract(bundle, dest)
        macos = dest / 'Darkbloom.app' / 'Contents' / 'MacOS'
        self.assertTrue((macos / 'mlx.metallib').exists())
        self.assertFalse((macos / '._mlx.metallib').exists())
        self.assertTrue((macos / '._orphan').exists())


class Q4SmokeChecks(QualifyTestCase):
    def test_missing_runtime_smoke_marker_fails_and_names_it(self):
        missing = 'paged-kernel-runtime-smoke'
        subset = [m for m in MARKERS if m != missing]

        def runtime_smoke(argv):
            return subprocess.CompletedProcess(argv, 0, '\n'.join(f'{m}: ok' for m in subset) + '\n', '')

        exit_code = self.invoke(fake_overrides={'runtime_smoke': runtime_smoke})
        result = self.load_result()
        checks = self.checks_by_name(result)
        self.assertEqual(checks['runtime-smoke']['status'], 'failed')
        self.assertEqual(checks['runtime-smoke']['detail'], f'missing runtime-smoke markers: {missing}')
        self.assertNotEqual(exit_code, 0)

    def test_marker_without_ok_does_not_count(self):
        def runtime_smoke(argv):
            return subprocess.CompletedProcess(argv, 0, '\n'.join(MARKERS) + '\n', '')

        exit_code = self.invoke(fake_overrides={'runtime_smoke': runtime_smoke})
        checks = self.checks_by_name(self.load_result())
        self.assertEqual(checks['runtime-smoke']['status'], 'failed')
        self.assertNotEqual(exit_code, 0)

    def test_wrong_version_output_fails_version_check(self):
        exit_code = self.invoke(fake_overrides={
            'app_version': lambda argv: subprocess.CompletedProcess(argv, 0, '0.9.7\n', ''),
        })
        result = self.load_result()
        checks = self.checks_by_name(result)
        self.assertEqual(checks['version']['status'], 'failed')
        self.assertNotEqual(exit_code, 0)


class Q5LaneAndLive(QualifyTestCase):
    def test_macos27_lane_on_older_host_fails_lane_host(self):
        exit_code = self.invoke(lane='macos-27', level='static,smoke',
                                 fake_overrides={'host_version': '26.2'})
        result = self.load_result()
        checks = self.checks_by_name(result)
        self.assertEqual(checks['lane-host']['status'], 'failed')
        self.assertNotEqual(exit_code, 0)

    def test_older_macos_lane_on_macos27_host_fails_lane_host(self):
        exit_code = self.invoke(lane='older-macos', level='static,smoke',
                                 fake_overrides={'host_version': '27.0', 'minos': '14.0'})
        result = self.load_result()
        checks = self.checks_by_name(result)
        self.assertEqual(checks['lane-host']['status'], 'failed')
        self.assertNotEqual(exit_code, 0)

    def test_live_level_without_env_stays_not_run_and_fails_the_run(self):
        exit_code = self.invoke(lane='older-macos', level='static,smoke,live')
        result = self.load_result()
        live_checks = [c for c in result['checks'] if c['level'] == 'live']
        self.assertTrue(live_checks, 'expected at least one live-level check when --level ...,live is requested')
        for check in live_checks:
            self.assertEqual(check['status'], 'not_run', check['name'])
            self.assertEqual(check['detail'], 'live lane not requested')
        # Requested-level checks did not all pass (the live ones did not run), so the run must fail closed.
        self.assertNotEqual(exit_code, 0)


class Q6InterruptionAndSignals(QualifyTestCase):
    def test_runtime_smoke_timeout_records_failed_never_passed(self):
        def timed_out(argv):
            raise subprocess.TimeoutExpired(argv, 30)

        exit_code = self.invoke(fake_overrides={'runtime_smoke': timed_out})
        result = self.load_result()
        checks = self.checks_by_name(result)
        self.assertEqual(checks['runtime-smoke']['status'], 'failed')
        self.assertIn('timeout', checks['runtime-smoke']['detail'].lower())
        self.assertNotEqual(exit_code, 0)

    def test_keyboard_interrupt_marks_in_progress_check_interrupted_and_writes_partial_output(self):
        def interrupted(argv):
            raise KeyboardInterrupt()

        try:
            exit_code = self.invoke(fake_overrides={'codesign_verify': interrupted})
        except KeyboardInterrupt:
            self.fail('KeyboardInterrupt escaped main(): C3 requires it to be caught and the '
                      'partial result still written to --output')

        result = self.load_result()
        checks = self.checks_by_name(result)
        for name in ['bundle-digest', 'binary-digest', 'metallib-digest', 'code-directory']:
            self.assertEqual(checks[name]['status'], 'passed', name)
        self.assertEqual(checks['codesign']['status'], 'failed')
        self.assertIn('interrupted', checks['codesign']['detail'].lower())
        for name in ['notarization', 'team-id', 'minimum-macos', 'lane-host', 'version', 'runtime-smoke']:
            self.assertEqual(checks[name]['status'], 'not_run', name)
        self.assertNotEqual(exit_code, 0)

    def test_signal_killed_process_records_failed_not_passed(self):
        exit_code = self.invoke(fake_overrides={
            'stapler': lambda argv: subprocess.CompletedProcess(argv, -9, '', ''),
        })
        result = self.load_result()
        checks = self.checks_by_name(result)
        self.assertEqual(checks['notarization']['status'], 'failed')
        self.assertNotEqual(exit_code, 0)


if __name__ == '__main__':
    unittest.main()
