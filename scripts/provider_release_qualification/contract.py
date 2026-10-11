"""Strict shared candidate and qualification receipt contract."""
import base64
from datetime import datetime, timedelta, timezone
import hashlib
import json
from pathlib import Path
import re
from urllib.parse import urlsplit

BUNDLE = 'darkbloom-bundle-macos-arm64.tar.gz'
CHECKS = frozenset({'signed_bundle', 'app_attest', 'encrypted_inference', 'lifecycle',
                    'tamper_replay', 'security_transitions', 'older_macos'})
RELEASE_FIELDS = frozenset({'version', 'platform', 'backend', 'binary_hash', 'bundle_hash',
                            'metallib_hash', 'url'})
BUILD_FIELDS = frozenset({'release', 'code_directory_hash', 'source_commit', 'ci_run_id'})
MAX_JSON_BYTES = 64 * 1024


def sha256(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def strict_json(data):
    if len(data) > MAX_JSON_BYTES:
        raise ValueError('JSON exceeds qualification size limit')

    def pairs(items):
        result = {}
        for key, value in items:
            if key in result:
                raise ValueError('Duplicate JSON field: ' + key)
            result[key] = value
        return result

    def constant(value):
        raise ValueError('Nonfinite JSON number: ' + value)

    return json.loads(data, object_pairs_hook=pairs, parse_constant=constant)


def fields(value, expected, label):
    if not isinstance(value, dict) or set(value) != set(expected):
        raise ValueError('Invalid ' + label + ' fields')


def text(value, pattern, label):
    if not isinstance(value, str) or re.fullmatch(pattern, value) is None:
        raise ValueError('Invalid ' + label)
    return value


def digest(value):
    return text(value, r'[0-9a-f]{64}', 'SHA-256 digest')


def positive(value, label):
    if type(value) is not int or value <= 0:
        raise ValueError('Invalid ' + label)


def validate_build(build):
    fields(build, BUILD_FIELDS, 'build')
    release = build['release']
    fields(release, RELEASE_FIELDS, 'release')
    text(release['version'], r'[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?', 'version')
    if release['platform'] != 'macos-arm64' or release['backend'] != 'mlx-swift':
        raise ValueError('Unsupported release platform/backend')
    for key in ('binary_hash', 'bundle_hash', 'metallib_hash'):
        digest(release[key])
    digest(build['code_directory_hash'])
    text(build['source_commit'], r'[0-9a-f]{40}', 'source commit')
    text(build['ci_run_id'], r'[1-9][0-9]*', 'signing run ID')
    url = urlsplit(release['url'])
    expected_suffix = f"/releases/v{release['version']}/artifacts/{release['bundle_hash']}/{BUNDLE}"
    if (url.scheme != 'https' or not url.hostname or url.username or url.password or
            url.query or url.fragment or not url.path.endswith(expected_suffix)):
        raise ValueError('Invalid immutable release URL')


def build_identity(payload):
    build = {key: payload[key] for key in BUILD_FIELDS - {'release'}}
    build['release'] = {key: payload[key] for key in RELEASE_FIELDS}
    validate_build(build)
    return build


def candidate(root, payload_sha256, provenance_sha256, source_commit, signing_run_id):
    """Anchor retained metadata to signing-job outputs, not the current attempt."""
    root = Path(root)
    for name, expected in [('release-payload.json', payload_sha256),
                           ('release-provenance.json', provenance_sha256)]:
        digest(expected)
        path = root / name
        if path.is_symlink() or sha256(path) != expected:
            raise ValueError('Retained candidate digest mismatch: ' + name)
    payload = strict_json((root / 'release-payload.json').read_bytes())
    fields(payload, RELEASE_FIELDS | (BUILD_FIELDS - {'release'}) |
           {'require_app_attest_qualification', 'changelog'}, 'candidate payload')
    build = build_identity(payload)
    if build['source_commit'] != source_commit or build['ci_run_id'] != signing_run_id:
        raise ValueError('Retained candidate source/signing run mismatch')
    if type(payload['require_app_attest_qualification']) is not bool or not isinstance(payload['changelog'], str):
        raise ValueError('Invalid candidate publication policy')
    provenance = strict_json((root / 'release-provenance.json').read_bytes())
    fields(provenance, {'source_commit', 'signing_workflow_commit', 'signing_run_id',
                       'signing_run_attempt', 'build_run_id', 'build_run_attempt',
                       'unsigned_artifact_id', 'unsigned_artifact_digest'}, 'provenance')
    if provenance['source_commit'] != source_commit or provenance['signing_run_id'] != signing_run_id:
        raise ValueError('Candidate provenance differs from release identity')
    text(provenance['signing_workflow_commit'], r'[0-9a-f]{40}', 'signing workflow commit')
    for key in ('signing_run_attempt', 'build_run_attempt', 'build_run_id'):
        text(provenance[key], r'[1-9][0-9]*', key)
    archive = root / BUNDLE
    if archive.is_symlink() or sha256(archive) != payload['bundle_hash']:
        raise ValueError('Staged signed bundle digest mismatch')
    return payload, build


def timestamp(value):
    text(value, r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})', 'RFC3339 timestamp')
    return datetime.fromisoformat(value.replace('Z', '+00:00'))


def validate_receipt(receipt, build, policy, run_id, run_attempt, now=None):
    fields(receipt, {'schema_version', 'build', 'qualification_run_id', 'qualification_run_attempt',
                     'policy_id', 'issued_at', 'expires_at', 'checks'}, 'receipt')
    if type(receipt['schema_version']) is not int or receipt['schema_version'] != 1:
        raise ValueError('Unsupported receipt schema')
    validate_build(receipt['build'])
    if receipt['build'] != build:
        raise ValueError('Qualification receipt candidate mismatch')
    text(policy, r'[A-Za-z0-9][A-Za-z0-9._:/-]{0,127}', 'qualification policy')
    text(run_id, r'[1-9][0-9]*', 'qualification run ID')
    positive(run_attempt, 'qualification run attempt')
    if (receipt['policy_id'] != policy or receipt['qualification_run_id'] != run_id or
            type(receipt['qualification_run_attempt']) is not int or receipt['qualification_run_attempt'] != run_attempt):
        raise ValueError('Qualification policy/run mismatch')
    issued, expires = timestamp(receipt['issued_at']), timestamp(receipt['expires_at'])
    now = now or datetime.now(timezone.utc)
    if issued > now or expires <= now or expires <= issued or expires - issued > timedelta(hours=1):
        raise ValueError('Qualification receipt expired, future-issued, or exceeds one hour')
    checks = receipt['checks']
    if not isinstance(checks, list) or len(checks) != len(CHECKS):
        raise ValueError('All qualification checks are mandatory')
    seen = set()
    for check in checks:
        fields(check, {'name', 'status', 'evidence_sha256'}, 'check')
        name = check['name']
        if not isinstance(name, str) or name not in CHECKS or name in seen or check['status'] != 'passed':
            raise ValueError('Missing, duplicate, unknown, or non-passing qualification check')
        digest(check['evidence_sha256'])
        seen.add(name)


def decode_envelope(envelope):
    fields(envelope, {'receipt', 'signature'}, 'signed envelope')
    try:
        raw = base64.b64decode(envelope['receipt'], validate=True)
        signature = base64.b64decode(envelope['signature'], validate=True)
    except (TypeError, ValueError) as exc:
        raise ValueError('Invalid signed envelope base64') from exc
    if len(signature) != 64:
        raise ValueError('Invalid Ed25519 signature length')
    return raw, signature
