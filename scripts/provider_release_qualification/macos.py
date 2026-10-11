"""Check final signed bytes on the named macOS lane without signing secrets."""
from datetime import datetime, timedelta, timezone
import hashlib
import json
from pathlib import Path, PurePosixPath
import plistlib
import re
import subprocess
import tarfile
import unicodedata

from .contract import BUNDLE, sha256, text
from .isolation import IsolatedCandidate

APP_ID = 'io.darkbloom.provider'
TEAM = 'SLDQ2GJ6TL'


def validate_entitlements(entitlements, profile):
    environment = 'com.apple.developer.devicecheck.appattest-environment'
    opt_in = 'com.apple.developer.devicecheck.app-attest-opt-in'
    grants = profile.get('Entitlements', {})
    # macOS Developer ID uses the CDhash opt-in; an environment grant is optional.
    signed_opt_in, granted_opt_in = entitlements.get(opt_in), grants.get(opt_in)
    if (signed_opt_in not in ('CDhash', ['CDhash']) or
            not (granted_opt_in == 'CDhash' or isinstance(granted_opt_in, list) and 'CDhash' in granted_opt_in)):
        raise ValueError('Signed executable/profile lacks App Attest CDhash opt-in')
    if environment in entitlements:
        grant = grants.get(environment)
        if entitlements[environment] != 'production' or not (
                grant in ('production', '*') or isinstance(grant, list) and 'production' in grant):
            raise ValueError('Signed App Attest environment is not authorized')
    if (TEAM + '.' + APP_ID not in entitlements.get('keychain-access-groups', []) or
            entitlements.get('com.apple.developer.aps-environment') != 'production' or
            any(key in entitlements for key in ('get-task-allow', 'com.apple.security.get-task-allow'))):
        raise ValueError('Signed executable entitlement policy mismatch')
    expires = profile.get('ExpirationDate')
    if (TEAM not in profile.get('TeamIdentifier', []) or not isinstance(expires, datetime) or
            expires.replace(tzinfo=timezone.utc) <= datetime.now(timezone.utc)):
        raise ValueError('Signed provisioning profile is expired or has the wrong team')


def validate_archive(path):
    if path.stat().st_size > 2 << 30:
        raise ValueError('Signed archive exceeds size limit')
    names, size = set(), 0
    with tarfile.open(path, 'r:gz') as archive:
        for member in archive:
            name = PurePosixPath(member.name)
            canonical = unicodedata.normalize('NFC', name.as_posix()).casefold()
            if (name.is_absolute() or '..' in name.parts or
                    not (member.isfile() or member.isdir()) or canonical in names):
                raise ValueError('Unsafe or duplicate signed archive member')
            names.add(canonical)
            size += member.size
            if member.size < 0 or member.size > 512 << 20 or size > 2 << 30 or len(names) > 16384:
                raise ValueError('Signed archive extraction limit exceeded')


def check_macos(root, build, output, major, run_id, run_attempt, policy):
    """Publish evidence only after every real command succeeds on exact bytes."""
    if major not in (26, 27):
        raise ValueError('Only macOS 26 and 27 are qualified by this lane')
    text(run_id, r'[1-9][0-9]*', 'qualification run ID')
    text(policy, r'[A-Za-z0-9][A-Za-z0-9._:/-]{0,127}', 'qualification policy')
    if type(run_attempt) is not int or run_attempt <= 0:
        raise ValueError('Invalid qualification run attempt')
    output.mkdir(parents=True, exist_ok=False)
    evidence = []

    def run(*args, env=None):
        result = subprocess.run(args, check=True, capture_output=True, env=env, timeout=180)
        evidence.append({'command': list(args), 'stdout': result.stdout.decode('utf-8', 'replace'),
                         'stderr': result.stderr.decode('utf-8', 'replace')})
        return result.stdout

    actual = run('/usr/bin/sw_vers', '-productVersion').decode().strip()
    if not re.fullmatch(str(major) + r'\.\d+(?:\.\d+)?', actual):
        raise ValueError('Signed artifact check is running on the wrong macOS major')
    if run('/usr/bin/uname', '-m').strip() != b'arm64':
        raise ValueError('Signed artifact requires real arm64 macOS')
    archive = root / BUNDLE
    if sha256(archive) != build['release']['bundle_hash']:
        raise ValueError('Signed archive digest mismatch')
    validate_archive(archive)
    extracted = output / 'extracted'
    extracted.mkdir()
    # Native tar preserves signing xattrs represented by AppleDouble entries.
    run('/usr/bin/tar', '-xzf', str(archive), '-C', str(extracted))
    app = extracted / 'Darkbloom.app'
    binary = app / 'Contents/MacOS/darkbloom'
    for name, field in [('darkbloom', 'binary_hash'), ('mlx.metallib', 'metallib_hash')]:
        for path in [extracted / 'bin' / name, app / 'Contents/MacOS' / name]:
            if not path.is_file() or path.is_symlink() or sha256(path) != build['release'][field]:
                raise ValueError('Signed app/flat binary digest mismatch: ' + name)
    requirement = f'anchor apple generic and identifier "{APP_ID}" and certificate leaf[subject.OU] = "{TEAM}"'
    run('/usr/bin/codesign', '--verify', '--deep', '--strict', '-R=' + requirement, str(app))
    run('/usr/bin/codesign', '--verify', '--strict', '-R=' + requirement, str(binary))
    run('/usr/bin/xcrun', 'stapler', 'validate', str(app))
    run('/usr/sbin/spctl', '--assess', '--type', 'execute', '--verbose=4', str(app))
    details = subprocess.run(['/usr/bin/codesign', '-d', '--verbose=4', str(binary)],
                             capture_output=True, check=True, timeout=30)
    details_text = details.stderr.decode()
    evidence.append({'codesign_details': details_text})
    if re.findall(r'^CandidateCDHashFull sha256=([0-9a-f]{64})$', details_text, re.M) != [build['code_directory_hash']]:
        raise ValueError('Signed CodeDirectory hash mismatch')
    flags = re.findall(r'^CodeDirectory\b[^\n]*\bflags=0x([0-9a-fA-F]+)\b', details_text, re.M)
    if len(flags) != 1 or not int(flags[0], 16) & 0x10000:
        raise ValueError('Signed executable lacks hardened runtime')
    entitlements = plistlib.loads(run('/usr/bin/codesign', '-d', '--entitlements', ':-', str(binary)))
    profile = plistlib.loads(run('/usr/bin/security', 'cms', '-D', '-i', str(app / 'Contents/embedded.provisionprofile')))
    validate_entitlements(entitlements, profile)
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    if any(info.get(key) != value for key, value in {
            'CFBundleIdentifier': APP_ID, 'CFBundleExecutable': 'darkbloom',
            'CFBundleVersion': build['release']['version'],
            'CFBundleShortVersionString': build['release']['version'], 'LSMinimumSystemVersion': '14.0'}.items()):
        raise ValueError('Signed Info.plist version/deployment target mismatch')
    load_commands = run('/usr/bin/xcrun', 'vtool', '-show-build', str(binary)).decode()
    if re.findall(r'^\s*minos\s+(\S+)', load_commands, re.M) != ['14.0']:
        raise ValueError('Signed Mach-O deployment target is not macOS 14.0')
    with IsolatedCandidate(app) as isolated:
        isolated_app = isolated.root / 'Darkbloom.app'
        isolated_binary = isolated_app / 'Contents/MacOS/darkbloom'
        if sha256(isolated_binary) != build['release']['binary_hash']:
            raise ValueError('Isolated executable digest mismatch')
        run('/usr/bin/codesign', '--verify', '--deep', '--strict', '-R=' + requirement, str(isolated_app))
        results = {}
        for command in ('--version', 'runtime-smoke'):
            result = isolated.run(command)
            evidence.append({'command': result.args, 'isolation': 'root-supervised-nobody-seatbelt',
                             'stdout': result.stdout.decode('utf-8', 'replace'),
                             'stderr': result.stderr.decode('utf-8', 'replace')})
            results[command] = result.stdout.decode()
        if results['--version'].strip() not in (build['release']['version'], 'darkbloom ' + build['release']['version']):
            raise ValueError('Signed executable version mismatch')
        for marker in ('app-attest-callback-runtime-smoke', 'gemma-optimizations-runtime-smoke',
                       'paged-kernel-runtime-smoke', 'qwen4-metal-resources-runtime-smoke'):
            if marker + ': ok' not in results['runtime-smoke'].splitlines():
                raise ValueError('Signed runtime smoke missing marker: ' + marker)
    # This evidence does not assert a DeviceCheck call or claim macOS 14 ran.
    evidence_bytes = json.dumps({'build': build, 'macos_version': actual, 'commands': evidence},
                                sort_keys=True).encode()
    evidence_hash = hashlib.sha256(evidence_bytes).hexdigest()
    (output / 'evidence').mkdir()
    (output / 'evidence' / evidence_hash).write_bytes(evidence_bytes)
    now = datetime.now(timezone.utc).replace(microsecond=0)
    report = {'schema_version': 1, 'build': build, 'qualification_run_id': run_id,
              'qualification_run_attempt': run_attempt, 'policy_id': policy,
              'issued_at': now.isoformat(), 'expires_at': (now + timedelta(hours=1)).isoformat(),
              'macos_major': major, 'check': {'name': 'older_macos' if major == 26 else 'signed_bundle',
                                             'status': 'passed', 'evidence_sha256': evidence_hash}}
    (output / 'report.json').write_text(json.dumps(report, sort_keys=True) + '\n')
    return report
