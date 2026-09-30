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


# --------------------------------------------------------------------------
# L1-L7: live checks bound to the candidate build and to the test requests.
# HTTP is faked at QUAL.urllib.request.urlopen (routed by method + URL), the
# process listing at subprocess.run (`ps -axo pid=,comm=`), and each running
# pid's `codesign -d --verbose=4 <pid>` answers with a cdhash that is or is not
# identity.code_directory_hash.
# --------------------------------------------------------------------------

COORD = 'https://coord.example'
OLD_ID = 'prov-old'
NEW_ID = 'prov-new'
SE_KEY = 'se-public-key-under-test'
API_KEY = 'qualify-api-key'
LIVE_ENV = {
    'DARKBLOOM_QUALIFY_LIVE': '1',
    'DARKBLOOM_QUALIFY_COORDINATOR': COORD,
    'DARKBLOOM_QUALIFY_PROVIDER_ID': OLD_ID,
    'DARKBLOOM_QUALIFY_API_KEY': API_KEY,
    'DARKBLOOM_QUALIFY_MODEL': 'model-under-test',
}
LIVE_NAMES = ['app-attest', 'inference', 'graceful-drain', 'accounting']
INFERENCE_REQ_ID = 'inf-1'
STREAM_REQ_ID = 'stream-1'


class _Headers(dict):
    def get(self, key, default=None):
        for k, v in self.items():
            if k.lower() == str(key).lower():
                return v
        return default


class _FakeResp:
    def __init__(self, status=200, headers=None, body=b'{}', lines=None):
        self.status = status
        self.headers = _Headers(headers or {})
        self._body = body
        self._lines = lines

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False

    def read(self, *args):
        return self._body

    def __iter__(self):
        return iter(self._lines if self._lines is not None else self._body.splitlines(keepends=True))


class FakeCoordinator:
    """Stateful stand-in for the coordinator. `provider_id` flips to NEW_ID
    when the `start` subprocess is faked (every reconnect gets a new id)."""

    def __init__(self):
        self.provider_id = OLD_ID
        self.requests = []          # (method, url, headers dict)
        self.header_override = {}   # 'inference' / 'stream' -> header value, or None to omit
        self.chat_status = 200
        self.usage_drop = set()     # request ids omitted from the ledger
        self.usage_zero = set()     # request ids with completion_tokens 0
        self.usage_extra = []       # unrelated ledger entries
        self.usage_status = 200     # non-200 makes GET /v1/payments/usage raise HTTPError
        self.job_header = {}        # 'inference' / 'stream' -> job id header override, or None to omit
        self.served = []            # request ids served

    def _provider_header(self, kind):
        if kind in self.header_override:
            value = self.header_override[kind]
            return {} if value is None else {'X-Provider-Id': value}
        return {'X-Provider-Id': self.provider_id}

    def _job_header(self, kind, default):
        value = self.job_header.get(kind, default)
        return {} if value is None else {'X-Inference-Job-ID': value}

    def urlopen(self, req, timeout=None, **kwargs):
        method = req.get_method()
        url = req.full_url
        headers = {k.lower(): v for k, v in req.header_items()}
        self.requests.append((method, url, headers))
        path = url[len(COORD):] if url.startswith(COORD) else url
        if method == 'GET' and path.split('?')[0] == '/v1/providers/attestation':
            entry = {'provider_id': self.provider_id, 'se_public_key': SE_KEY,
                     'app_attest_authorized': True,
                     'verification': {'app_attest': {'state': 'verified'}}}
            return _FakeResp(body=json.dumps({'providers': [entry]}).encode())
        if method == 'POST' and path.split('?')[0] == '/v1/chat/completions':
            if self.chat_status != 200:
                import urllib.error
                raise urllib.error.HTTPError(url, self.chat_status, 'fake', {}, io.BytesIO(b'{}'))
            body = json.loads(req.data.decode())
            if body.get('stream'):
                self.served.append(STREAM_REQ_ID)
                chunks = [
                    {'id': 'chatcmpl_9F3A0C', 'choices': [{'delta': {'content': '1\n'}}]},
                    {'id': 'chatcmpl_9F3A0C', 'choices': [{'delta': {}, 'finish_reason': 'stop'}]},
                ]
                lines = [b'data: ' + json.dumps(c).encode() + b'\n' for c in chunks] + [b'data: [DONE]\n']
                headers = dict(self._provider_header('stream'), **self._job_header('stream', STREAM_REQ_ID))
                return _FakeResp(headers=headers, lines=lines)
            self.served.append(INFERENCE_REQ_ID)
            data = {'id': 'chatcmpl-' + INFERENCE_REQ_ID,
                    'choices': [{'message': {'content': 'ok'}}]}
            headers = dict(self._provider_header('inference'), **self._job_header('inference', INFERENCE_REQ_ID))
            return _FakeResp(headers=headers, body=json.dumps(data).encode())
        if method == 'GET' and path.split('?')[0] == '/v1/payments/usage':
            if self.usage_status != 200:
                import urllib.error
                raise urllib.error.HTTPError(url, self.usage_status, 'Unauthorized', {}, io.BytesIO(b'{}'))
            entries = []
            for rid in self.served:
                if rid in self.usage_drop:
                    continue
                entries.append({'job_id': rid, 'model': 'm', 'prompt_tokens': 3,
                                'completion_tokens': 0 if rid in self.usage_zero else 5})
            entries += self.usage_extra
            return _FakeResp(body=json.dumps({'usage': entries}).encode())
        if method == 'GET' and path.split('?')[0] == '/v1/stats':
            return _FakeResp(body=json.dumps({'providers': [{'id': self.provider_id, 'requests_served': 0}]}).encode())
        raise AssertionError('unfaked HTTP call: %s %s' % (method, url))


class LiveQualifyTestCase(QualifyTestCase):
    def setUp(self):
        super().setUp()
        self.coord = FakeCoordinator()
        self.subproc_calls = []
        self.ps_lines = None  # None -> one darkbloom process (pid 4242) running the candidate build
        self.pid_codesign = {}  # pid -> CompletedProcess override for `codesign -d --verbose=4 <pid>`
        self.running_bin = '/Applications/Darkbloom.app/Contents/MacOS/darkbloom'

    def invoke_live(self, lane='macos-27', deadline=0.05):
        self.assert_deadline_seam()
        base = make_fake_tools({'host_version': '27.0', 'minos': '14.0'})
        coord = self.coord
        test = self

        def fake(argv, *args, **kwargs):
            argv = list(argv)
            test.subproc_calls.append(argv)
            if argv[:1] == ['ps']:
                lines = test.ps_lines
                if lines is None:
                    lines = [f'4242 {test.running_bin}']
                return subprocess.CompletedProcess(argv, 0, '\n'.join(lines) + '\n', '')
            if argv[:3] == ['codesign', '-d', '--verbose=4'] and str(argv[-1]).isdigit():
                # A bare pid reads the file on disk, not the running image.
                return subprocess.CompletedProcess(argv, 1, '', 'bare pid: use +pid for the running image')
            if argv[:3] == ['codesign', '-d', '--verbose=4'] and str(argv[-1]).startswith('+'):
                pid = str(argv[-1])[1:]
                if pid in test.pid_codesign:
                    return test.pid_codesign[pid](argv)
                return _codesign_reply(GOOD_CODE_DIRECTORY_HASH)(argv)
            if len(argv) >= 2 and argv[1] == 'stop':
                return subprocess.CompletedProcess(argv, 0, '', '')
            if len(argv) >= 2 and argv[1] == 'start':
                coord.provider_id = NEW_ID  # reconnect: new id, same SE key
                return subprocess.CompletedProcess(argv, 0, '', '')
            return base(argv, *args, **kwargs)

        argv = ['provider-release-qualify.py', '--directory', str(self.dir),
                '--lane', lane, '--level', 'static,smoke,live', '--output', str(self.out)]
        with mock.patch.dict(os.environ, LIVE_ENV, clear=False), \
             mock.patch.object(QUAL.subprocess, 'run', side_effect=fake), \
             mock.patch.object(QUAL.urllib.request, 'urlopen', side_effect=coord.urlopen), \
             mock.patch.object(QUAL.time, 'sleep', lambda s: None), \
             mock.patch.object(QUAL, 'ACCOUNTING_DEADLINE_SECONDS', deadline, create=True), \
             mock.patch.object(sys, 'argv', argv):
            try:
                rc = QUAL.main()
            except SystemExit as exc:
                rc = exc.code
        result = self.load_result()
        return (0 if rc is None else rc), self.checks_by_name(result)

    def assert_deadline_seam(self):
        # The implementer reads the polling deadline from this module constant;
        # without it an accounting failure would spin for the real 120 s.
        self.assertTrue(hasattr(QUAL, 'ACCOUNTING_DEADLINE_SECONDS'),
                        'QUAL.ACCOUNTING_DEADLINE_SECONDS is missing (accounting deadline seam)')


def _codesign_reply(cdhash, executable='/Applications/Darkbloom.app/Contents/MacOS/darkbloom'):
    def reply(argv):
        stderr = f'Executable={executable}\nCandidateCDHashFull sha256={cdhash}\nTeamIdentifier={TEAM_ID}\n'
        return subprocess.CompletedProcess(argv, 0, '', stderr)
    return reply


class L1BuildBindingPasses(LiveQualifyTestCase):
    def test_l1_running_cdhash_equals_code_directory_hash_live_checks_proceed(self):
        self.assert_deadline_seam()
        self.ps_lines = [f'4242 {self.running_bin}', f'4243 {self.running_bin}',
                         '100 /usr/bin/ssh', '555 /nonexistent/darkbloom-enclave']
        rc, checks = self.invoke_live()
        for name in LIVE_NAMES:
            self.assertEqual(checks[name]['status'], 'passed', (name, checks[name]['detail']))
        self.assertIn(['ps', '-axo', 'pid=,comm='], self.subproc_calls)
        self.assertIn(['codesign', '-d', '--verbose=4', '+4242'], self.subproc_calls)
        self.assertIn(['codesign', '-d', '--verbose=4', '+4243'], self.subproc_calls)
        self.assertEqual(rc, 0)

    def test_l1_uppercase_reported_cdhash_matches(self):
        self.pid_codesign['4242'] = _codesign_reply(GOOD_CODE_DIRECTORY_HASH.upper())
        rc, checks = self.invoke_live()
        for name in LIVE_NAMES:
            self.assertEqual(checks[name]['status'], 'passed', (name, checks[name]['detail']))


class L2BuildBindingFails(LiveQualifyTestCase):
    def assert_all_live_fail_naming(self, checks, *needles):
        for name in LIVE_NAMES:
            self.assertEqual(checks[name]['status'], 'failed', (name, checks[name]['detail']))
            for needle in needles:
                self.assertIn(needle, checks[name]['detail'], name)
        posts = [r for r in self.coord.requests if r[0] == 'POST']
        self.assertEqual(posts, [], 'no test request may be sent before the build binding holds')
        self.assertFalse([c for c in self.subproc_calls if len(c) > 1 and c[1] in ('stop', 'start')],
                         'the provider must not be stopped or restarted before the build binding holds')

    def test_l2_cdhash_differs_every_live_check_fails_naming_pid_executable_and_hashes(self):
        bad = 'ef' * 32
        self.pid_codesign['4242'] = _codesign_reply(bad, '/tmp/other/darkbloom')
        rc, checks = self.invoke_live()
        self.assert_all_live_fail_naming(checks, '4242', '/tmp/other/darkbloom', bad, GOOD_CODE_DIRECTORY_HASH)
        self.assertNotEqual(rc, 0)

    def test_l2_one_of_two_processes_differs_every_live_check_fails(self):
        self.ps_lines = [f'4242 {self.running_bin}', f'4243 {self.running_bin}']
        self.pid_codesign['4243'] = _codesign_reply('cd' * 32)
        rc, checks = self.invoke_live()
        self.assert_all_live_fail_naming(checks, '4243')
        self.assertNotEqual(rc, 0)

    def test_l2_no_darkbloom_process_every_live_check_fails(self):
        self.ps_lines = ['100 /usr/bin/ssh', '555 /nonexistent/darkbloom-enclave', '556 /bin/zsh']
        rc, checks = self.invoke_live()
        self.assert_all_live_fail_naming(checks)
        for name in LIVE_NAMES:
            self.assertIn('process', checks[name]['detail'].lower(), name)
        self.assertNotEqual(rc, 0)

    def test_l2_codesign_failure_for_a_pid_is_reported_never_passed(self):
        self.pid_codesign['4242'] = lambda argv: subprocess.CompletedProcess(argv, 1, '', 'no such process')
        rc, checks = self.invoke_live()
        self.assert_all_live_fail_naming(checks, '4242')
        self.assertNotEqual(rc, 0)

    def test_l2_codesign_without_cdhash_for_a_pid_is_reported_never_passed(self):
        self.pid_codesign['4242'] = lambda argv: subprocess.CompletedProcess(argv, 0, '', 'Executable=/x\n')
        rc, checks = self.invoke_live()
        self.assert_all_live_fail_naming(checks, '4242')
        self.assertNotEqual(rc, 0)


class L3RequestBinding(LiveQualifyTestCase):
    def test_l3_inference_from_another_provider_fails(self):
        self.assert_deadline_seam()
        self.coord.header_override['inference'] = 'someone-else'
        rc, checks = self.invoke_live()
        self.assertEqual(checks['inference']['status'], 'failed', checks['inference']['detail'])
        self.assertIn('X-Provider-Id', checks['inference']['detail'])
        self.assertNotEqual(rc, 0)

    def test_l3_inference_missing_provider_header_fails(self):
        self.assert_deadline_seam()
        self.coord.header_override['inference'] = None
        rc, checks = self.invoke_live()
        self.assertEqual(checks['inference']['status'], 'failed', checks['inference']['detail'])
        self.assertNotEqual(rc, 0)

    def test_l3_drain_stream_from_another_provider_fails(self):
        self.assert_deadline_seam()
        self.coord.header_override['stream'] = 'someone-else'
        rc, checks = self.invoke_live()
        self.assertEqual(checks['graceful-drain']['status'], 'failed', checks['graceful-drain']['detail'])
        self.assertNotEqual(rc, 0)


    def test_l3_inference_missing_job_id_header_fails_naming_it(self):
        self.coord.job_header['inference'] = None
        rc, checks = self.invoke_live()
        self.assertEqual(checks['inference']['status'], 'failed', checks['inference']['detail'])
        self.assertIn('X-Inference-Job-ID', checks['inference']['detail'])
        self.assertNotEqual(rc, 0)

    def test_l3_drain_stream_missing_job_id_header_fails_naming_it(self):
        self.coord.job_header['stream'] = None
        rc, checks = self.invoke_live()
        self.assertEqual(checks['graceful-drain']['status'], 'failed', checks['graceful-drain']['detail'])
        self.assertIn('X-Inference-Job-ID', checks['graceful-drain']['detail'])
        self.assertNotEqual(rc, 0)


class L4L7Accounting(LiveQualifyTestCase):
    def setUp(self):
        super().setUp()
        self.assert_deadline_seam()

    def test_l4_reconnect_during_drain_accounting_uses_recorded_request_ids(self):
        rc, checks = self.invoke_live()
        self.assertEqual(self.coord.provider_id, NEW_ID, 'fixture: start must have flipped the provider id')
        self.assertEqual(checks['graceful-drain']['status'], 'passed', checks['graceful-drain']['detail'])
        self.assertEqual(checks['accounting']['status'], 'passed', checks['accounting']['detail'])
        urls = [u for _, u, _ in self.coord.requests]
        self.assertFalse([u for u in urls if '/v1/stats' in u], 'requests_served baseline must be gone')
        self.assertFalse([u for u in urls if OLD_ID in u], 'no lookup by the stale provider id')
        usage = [r for r in self.coord.requests if r[0] == 'GET' and r[1].split('?')[0] == COORD + '/v1/payments/usage']
        self.assertTrue(usage, 'accounting must read GET /v1/payments/usage')
        self.assertEqual(usage[0][2].get('authorization'), 'Bearer ' + API_KEY)
        self.assertEqual(rc, 0)

    def test_l4_recorded_ids_are_the_job_id_headers_not_the_body_ids(self):
        # The stream chunks carry chatcmpl_9F3A0C and the body id is chatcmpl-...; only the
        # X-Inference-Job-ID header values are ledger job ids.
        self.coord.usage_extra = [{'job_id': 'chatcmpl_9F3A0C', 'completion_tokens': 9},
                                  {'job_id': 'chatcmpl-' + INFERENCE_REQ_ID, 'completion_tokens': 9}]
        self.coord.usage_drop = {INFERENCE_REQ_ID, STREAM_REQ_ID}
        _, checks = self.invoke_live()
        self.assertEqual(checks['accounting']['status'], 'failed', checks['accounting']['detail'])

    def test_l4_stream_with_chatcmpl_underscore_chunk_id_accounts_for_header_job_id(self):
        self.coord.usage_drop = {STREAM_REQ_ID}
        _, checks = self.invoke_live()
        self.assertEqual(checks['accounting']['status'], 'failed', checks['accounting']['detail'])
        self.assertIn('stream-1', checks['accounting']['detail'])
        self.assertNotIn('chatcmpl_9F3A0C', checks['accounting']['detail'])

    def test_l8_usage_401_keeps_polling_and_reports_last_error(self):
        self.coord.usage_status = 401
        rc, checks = self.invoke_live()
        self.assertEqual(checks['accounting']['status'], 'failed', checks['accounting']['detail'])
        self.assertIn('last usage error', checks['accounting']['detail'])
        self.assertIn('401', checks['accounting']['detail'])
        self.assertNotEqual(rc, 0)

    def test_l5_ledger_lacks_one_recorded_request_id_accounting_fails(self):
        self.coord.usage_drop = {STREAM_REQ_ID}
        rc, checks = self.invoke_live()
        self.assertEqual(checks['accounting']['status'], 'failed', checks['accounting']['detail'])
        self.assertIn(STREAM_REQ_ID, checks['accounting']['detail'])
        self.assertNotEqual(rc, 0)

    def test_l5_completion_tokens_zero_accounting_fails(self):
        self.coord.usage_zero = {INFERENCE_REQ_ID}
        rc, checks = self.invoke_live()
        self.assertEqual(checks['accounting']['status'], 'failed', checks['accounting']['detail'])
        self.assertNotEqual(rc, 0)

    def test_l5_unrelated_entries_never_stand_in_for_a_missing_id(self):
        self.coord.usage_drop = {INFERENCE_REQ_ID}
        self.coord.usage_extra = [{'job_id': f'other-{i}', 'completion_tokens': 50} for i in range(5)]
        rc, checks = self.invoke_live()
        self.assertEqual(checks['accounting']['status'], 'failed', checks['accounting']['detail'])
        self.assertNotEqual(rc, 0)

    def test_l6_unrelated_usage_entries_with_test_ids_present_passes(self):
        self.coord.usage_extra = [{'job_id': 'unrelated-1', 'completion_tokens': 7},
                                  {'job_id': 'unrelated-2', 'completion_tokens': 0}]
        rc, checks = self.invoke_live()
        self.assertEqual(checks['accounting']['status'], 'passed', checks['accounting']['detail'])
        self.assertEqual(rc, 0)

    def test_l7_no_recorded_test_requests_accounting_fails(self):
        self.coord.chat_status = 503  # inference and drain stream both fail, nothing is recorded
        rc, checks = self.invoke_live()
        self.assertEqual(checks['accounting']['status'], 'failed', checks['accounting']['detail'])
        self.assertIn('no test requests to account for', checks['accounting']['detail'])
        self.assertNotEqual(rc, 0)


if __name__ == '__main__':
    unittest.main()
