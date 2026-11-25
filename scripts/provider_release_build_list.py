"""The signed provider-build list: the production provider builds a verifier accepts.

The document (`provider-builds.json`) names each qualified production build by
its version, full CodeDirectory SHA-256, binary SHA-256 and source commit, and
a version floor (`min_version`). A compact JWS signed with the provider-release
key (Ed25519) carries the exact document bytes. A verifier accepts a list only
when its protected header is exactly
`{"alg":"Ed25519","kid":"<pinned key ID>","typ":"darkbloom-provider-builds+jws"}`,
the signature verifies with that pinned key, the document is in its canonical
form with this app ID and environment, it has not expired, and its sequence
number is not below the highest one the verifier has accepted. A build matches
only when it is listed, not revoked and not below `min_version`.

Only four changes make the next list, each with the next sequence number and
new dates (an 8-day lifetime):

  release    adds exactly one build, this release's, from its digest-checked
             registration payload
  republish  keeps every build and the floor byte for byte
  revoke     flips named builds from revoked false to true
  floor      raises min_version and drops only the builds below it

A build is never removed otherwise, a revocation is never undone, the floor
never falls, and a revoked or dropped build is never listed again.

Ed25519 runs through the OpenSSL 3 command line: Python's standard library has
no Ed25519, and the release jobs install no package for it.
"""
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import urllib.error
import urllib.parse
import urllib.request

DOCUMENT_TYPE = 'darkbloom-provider-builds'
JWS_TYPE = 'darkbloom-provider-builds+jws'
APP_ID = 'SLDQ2GJ6TL.io.darkbloom.provider'
TEAM_ID = 'SLDQ2GJ6TL'
ENVIRONMENT = 'production'
DAY = 24 * 3600
LIFETIME = 8 * DAY
# The daily check asks for the next re-publication once the list is this old,
# and escalates when no more than this is left.
RESIGN_DUE_AGE = 4 * DAY
ESCALATION_WINDOW = 2 * DAY
# A prepared document is signed and published within this time of its issue
# time, or prepared again.
MAXIMUM_SIGNING_DELAY = 2 * DAY
CLOCK_SKEW = 300
# The signer's raw-input limit for one signature: pure Ed25519 signs the whole
# signing input. A list beyond it can't be signed; half of it gives a warning.
SIGNING_INPUT_LIMIT = 1 << 20
MAXIMUM_KEYS = 2
# Verifiers match a 20-byte CodeDirectory prefix only when it is unique over
# every listed entry, revoked ones included, so no two entries share one.
PREFIX_HEX = 40

DOCUMENT_FIELDS = ('v', 'typ', 'app_id', 'environment', 'seq', 'issued_at', 'expires_at', 'min_version', 'builds')
BUILD_FIELDS = ('version', 'code_directory_hash', 'binary_sha256', 'source_commit', 'revoked')
OPERATIONS = ('release', 'republish', 'revoke', 'floor')
VERSION = re.compile(r'(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)')
DIGEST = re.compile(r'[0-9a-f]{64}')
COMMIT = re.compile(r'[0-9a-f]{40}')
COMPACT_JWS = re.compile(r'[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+')

DOCUMENT_NAME = 'provider-builds.json'
LIST_NAME = 'provider-builds.jws'
SEQUENCE_NAME = re.compile(r'provider-builds-([1-9][0-9]*)\.jws')
MAXIMUM_LIST_BYTES = SIGNING_INPUT_LIMIT + 1024
# The hosts a list download may reach: GitHub, and the host its
# release-asset downloads redirect to.
FETCH_HOSTS = ('github.com', 'release-assets.githubusercontent.com')

SCRIPTS = Path(__file__).resolve().parent
# The provider-release public keys a published list must verify with (at most
# two: the current key and the next). Empty until a signing key is configured,
# so `publish` refuses every list until then.
PINNED_KEYS = SCRIPTS / 'provider-release-build-list-keys.json'
# The list a dry-run re-publication starts from.
DRY_RUN_DOCUMENT = SCRIPTS / 'provider-release-build-list-dry-run.json'

# RFC 8032 section 7.1, TEST 1. The key is published, so a list it signs is
# recognisably a test list; no verifier pins it, and the pinned key file must
# never list it (scripts/test-provider-release-build-list.py).
TEST_SEED = bytes.fromhex('9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60')
TEST_PUBLIC_KEY = bytes.fromhex('d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a')

PKCS8_ED25519_PREFIX = bytes.fromhex('302e020100300506032b657004220420')
SPKI_ED25519_PREFIX = bytes.fromhex('302a300506032b6570032100')


# Encoding.

def b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b'=').decode('ascii')


def unb64url(text):
    """Decode unpadded base64url, refusing any other spelling of the same bytes."""
    if not re.fullmatch(r'[A-Za-z0-9_-]*', text) or len(text) % 4 == 1:
        raise ValueError('Not unpadded base64url')
    data = base64.urlsafe_b64decode(text + '=' * (-len(text) % 4))
    if b64url(data) != text:
        raise ValueError('Not canonical base64url')
    return data


def key_id(public_key):
    """The RFC 7638 thumbprint of an Ed25519 public key (RFC 8037 OKP members)."""
    members = '{"crv":"Ed25519","kty":"OKP","x":"%s"}' % b64url(public_key)
    return b64url(hashlib.sha256(members.encode('ascii')).digest())


def protected_header(kid):
    return ('{"alg":"Ed25519","kid":"%s","typ":"%s"}' % (kid, JWS_TYPE)).encode('ascii')


def version_key(version):
    return tuple(int(part) for part in version.split('.'))


# The document.

def check_build(build):
    if not isinstance(build, dict) or set(build) != set(BUILD_FIELDS):
        raise ValueError('A build has exactly the fields ' + ', '.join(BUILD_FIELDS))
    checks = (('version', VERSION), ('code_directory_hash', DIGEST), ('binary_sha256', DIGEST),
              ('source_commit', COMMIT))
    for field, pattern in checks:
        if not isinstance(build[field], str) or not pattern.fullmatch(build[field]):
            raise ValueError(f'Invalid build {field}')
    if type(build['revoked']) is not bool:
        raise ValueError('Invalid build revoked')


def check_document(document):
    if not isinstance(document, dict) or set(document) != set(DOCUMENT_FIELDS):
        raise ValueError('The list document has exactly the fields ' + ', '.join(DOCUMENT_FIELDS))
    expected = {'v': 1, 'typ': DOCUMENT_TYPE, 'app_id': APP_ID, 'environment': ENVIRONMENT}
    for field, value in expected.items():
        if type(document[field]) is not type(value) or document[field] != value:
            raise ValueError(f'The list document {field} must be {value!r}')
    for field in ('seq', 'issued_at', 'expires_at'):
        if type(document[field]) is not int or document[field] < (1 if field == 'seq' else 0):
            raise ValueError(f'Invalid list {field}')
    if not 0 < document['expires_at'] - document['issued_at'] <= LIFETIME:
        raise ValueError('A list expires after its issue time and at most 8 days after it')
    if not isinstance(document['min_version'], str) or not VERSION.fullmatch(document['min_version']):
        raise ValueError('Invalid list min_version')
    builds = document['builds']
    if not isinstance(builds, list) or not builds:
        raise ValueError('A list names at least one build')
    for build in builds:
        check_build(build)
        if version_key(build['version']) < version_key(document['min_version']):
            raise ValueError(f'Build {build["version"]} is below the list min_version')
    for field, width in (('version', None), ('code_directory_hash', None), ('code_directory_hash', PREFIX_HEX)):
        values = [build[field][:width] for build in builds]
        if len(set(values)) != len(values):
            raise ValueError(f'Two builds share a {field}' + (' prefix' if width else ''))


def document_bytes(document):
    """The canonical document: these fields in this order, no whitespace, ASCII."""
    check_document(document)
    ordered = {field: document[field] for field in DOCUMENT_FIELDS}
    ordered['builds'] = [{field: build[field] for field in BUILD_FIELDS} for build in document['builds']]
    return json.dumps(ordered, separators=(',', ':'), ensure_ascii=True).encode('ascii')


def parse_document(data):
    """The document of canonical bytes; any other encoding of it is refused."""
    try:
        document = json.loads(data)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ValueError('The list document is not JSON') from error
    if document_bytes(document) != data:
        raise ValueError('The list document is not in its canonical form')
    return document


def document_sha256(document):
    return hashlib.sha256(document_bytes(document)).hexdigest()


# Keys.

def load_keys(path=PINNED_KEYS):
    """[(kid, raw public key)] of a key file: {"keys": [{"kid", "public_key"}]}, at most two."""
    data = json.loads(Path(path).read_text())
    if not isinstance(data, dict) or set(data) != {'keys'} or not isinstance(data['keys'], list):
        raise ValueError('A key file is {"keys": [...]}')
    if len(data['keys']) > MAXIMUM_KEYS:
        raise ValueError('At most two provider-release keys are pinned: the current one and the next')
    keys = []
    for entry in data['keys']:
        if not isinstance(entry, dict) or set(entry) != {'kid', 'public_key'}:
            raise ValueError('A pinned key is {"kid", "public_key"}')
        public = base64.b64decode(entry['public_key'], validate=True)
        if len(public) != 32 or base64.b64encode(public).decode('ascii') != entry['public_key']:
            raise ValueError('A pinned public key is the standard base64 of 32 raw bytes')
        if entry['kid'] != key_id(public):
            raise ValueError('A pinned key ID is not the thumbprint of its public key')
        keys.append((entry['kid'], public))
    if len({kid for kid, _ in keys}) != len(keys):
        raise ValueError('A key is pinned twice')
    return keys


def keys_text(public_keys):
    entries = [{'kid': key_id(public), 'public_key': base64.b64encode(public).decode('ascii')}
               for public in public_keys]
    return json.dumps({'keys': entries}, indent=2) + '\n'


# Ed25519.

class OpenSSL:
    """Ed25519 signing and verification through the OpenSSL 3 command line
    (`OPENSSL`, else `openssl` on PATH). LibreSSL and OpenSSL 1.x are refused."""

    def __init__(self, path=None):
        self.path = path or os.environ.get('OPENSSL') or shutil.which('openssl')
        if not self.path:
            raise RuntimeError('Ed25519 needs the OpenSSL 3 command line; none was found (set OPENSSL)')
        version = subprocess.run([self.path, 'version'], capture_output=True, text=True, check=True,
                                 timeout=60).stdout
        if not re.match(r'OpenSSL [3-9]\.', version):
            raise RuntimeError(f'Ed25519 needs OpenSSL 3 or later, not {version.strip()!r} (set OPENSSL)')

    def _run(self, *args):
        return subprocess.run([self.path, *args], capture_output=True, timeout=60)

    def _with_private_key(self, seed, operation):
        with tempfile.TemporaryDirectory(prefix='provider-build-list-') as directory:
            key = Path(directory) / 'key.pem'
            descriptor = os.open(key, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(descriptor, 'w') as stream:
                stream.write(pem('PRIVATE KEY', PKCS8_ED25519_PREFIX + seed))
            return operation(Path(directory), key)

    def sign(self, seed, message):
        def operation(directory, key):
            (directory / 'message').write_bytes(message)
            result = self._run('pkeyutl', '-sign', '-inkey', str(key), '-rawin', '-in', str(directory / 'message'),
                               '-out', str(directory / 'signature'))
            if result.returncode != 0:
                raise RuntimeError('OpenSSL could not sign: ' + result.stderr.decode(errors='replace').strip())
            return (directory / 'signature').read_bytes()
        return self._with_private_key(seed, operation)

    def public_key(self, seed):
        def operation(directory, key):
            result = self._run('pkey', '-in', str(key), '-pubout', '-outform', 'DER')
            if result.returncode != 0 or not result.stdout.startswith(SPKI_ED25519_PREFIX):
                raise RuntimeError('OpenSSL could not derive an Ed25519 public key')
            return result.stdout[len(SPKI_ED25519_PREFIX):]
        return self._with_private_key(seed, operation)

    def verify(self, public_key, message, signature):
        with tempfile.TemporaryDirectory(prefix='provider-build-list-') as directory:
            directory = Path(directory)
            (directory / 'public.pem').write_text(pem('PUBLIC KEY', SPKI_ED25519_PREFIX + public_key))
            (directory / 'message').write_bytes(message)
            (directory / 'signature').write_bytes(signature)
            result = self._run('pkeyutl', '-verify', '-pubin', '-inkey', str(directory / 'public.pem'), '-rawin',
                               '-in', str(directory / 'message'), '-sigfile', str(directory / 'signature'))
            return result.returncode == 0


def pem(label, der):
    body = base64.b64encode(der).decode('ascii')
    lines = [body[index:index + 64] for index in range(0, len(body), 64)]
    return '\n'.join([f'-----BEGIN {label}-----', *lines, f'-----END {label}-----', ''])


class TestSigner:
    """The RFC 8032 test key. A list it signs is a dry run: no verifier pins
    the key, and `publish` refuses a list no pinned key verifies."""
    name = 'test'

    def __init__(self, openssl):
        self.openssl = openssl
        if openssl.public_key(TEST_SEED) != TEST_PUBLIC_KEY:
            raise RuntimeError('OpenSSL derived another public key from the RFC 8032 test key')
        self.public_key = TEST_PUBLIC_KEY

    def sign(self, message):
        return self.openssl.sign(TEST_SEED, message)


def signer(name, openssl):
    if name == TestSigner.name:
        return TestSigner(openssl)
    raise ValueError(f'Unknown signer {name!r}: only the test signer exists until a signing key is configured')


# The signed list.

def signing_input(document, kid):
    return b64url(protected_header(kid)) + '.' + b64url(document_bytes(document))


def size_warning(document):
    """None while the signing input is under half of the signer's limit, else a
    warning; refuses a list over the limit."""
    size = len(signing_input(document, key_id(TEST_PUBLIC_KEY)))
    if size > SIGNING_INPUT_LIMIT:
        raise ValueError(f'The list\'s signing input is {size} bytes, over the signer\'s limit of '
                         f'{SIGNING_INPUT_LIMIT} bytes; raise min_version')
    if size * 2 >= SIGNING_INPUT_LIMIT:
        return (f'The list\'s signing input is {size} bytes, at least half of the signer\'s limit of '
                f'{SIGNING_INPUT_LIMIT} bytes; plan a min_version raise')
    return None


def sign_list(document, signer_):
    """The compact JWS of a document, signed with `signer_`."""
    size_warning(document)
    text = signing_input(document, key_id(signer_.public_key))
    signature = signer_.sign(text.encode('ascii'))
    if len(signature) != 64:
        raise RuntimeError('An Ed25519 signature is 64 bytes')
    return text + '.' + b64url(signature)


def verify_list(jws, keys, openssl, now, minimum_seq=1, allow_expired=False):
    """The document of a list that verifies with one of `keys`; refuses anything else."""
    if not isinstance(jws, str) or not COMPACT_JWS.fullmatch(jws):
        raise ValueError('Not a compact JWS')
    encoded_header, encoded_payload, encoded_signature = jws.split('.')
    header = unb64url(encoded_header)
    public = next((public for kid, public in keys if protected_header(kid) == header), None)
    if public is None:
        raise ValueError('The list header is not exactly the provider-build list header with a pinned key ID')
    signature = unb64url(encoded_signature)
    message = (encoded_header + '.' + encoded_payload).encode('ascii')
    if len(signature) != 64 or not openssl.verify(public, message, signature):
        raise ValueError('The list signature does not verify')
    document = parse_document(unb64url(encoded_payload))
    if not allow_expired and document['expires_at'] <= now:
        raise ValueError('The list has expired')
    if document['seq'] < minimum_seq:
        raise ValueError(f'The list sequence number {document["seq"]} is below {minimum_seq}')
    return document


def unverified_document(jws):
    """The document a list carries, without its signature checked."""
    if not isinstance(jws, str) or not COMPACT_JWS.fullmatch(jws):
        raise ValueError('Not a compact JWS')
    return parse_document(unb64url(jws.split('.')[1]))


def read_list(path):
    data = Path(path).read_bytes()
    if len(data) > MAXIMUM_LIST_BYTES:
        raise ValueError('The list is too large')
    return data.decode('ascii')


# The next list.

def build_entry(payload):
    """The list entry of a release's retained registration payload."""
    entry = {'version': payload['version'], 'code_directory_hash': payload['code_directory_hash'],
             'binary_sha256': payload['binary_hash'], 'source_commit': payload['source_commit'], 'revoked': False}
    check_build(entry)
    return entry


def change_text(change):
    return json.dumps(change, sort_keys=True)


def check_change(change):
    operation = change.get('operation') if isinstance(change, dict) else None
    fields = {'release': {'operation', 'build'}, 'republish': {'operation'},
              'revoke': {'operation', 'versions'}, 'floor': {'operation', 'min_version'}}
    if operation not in fields or set(change) != fields[operation]:
        raise ValueError('A change is one of: ' + ', '.join(OPERATIONS))
    if operation == 'release':
        check_build(change['build'])
        if change['build']['revoked']:
            raise ValueError('A release adds a build that is not revoked')
    if operation == 'revoke':
        versions = change['versions']
        if (not isinstance(versions, list) or not versions or len(set(versions)) != len(versions)
                or not all(isinstance(version, str) and VERSION.fullmatch(version) for version in versions)):
            raise ValueError('A revocation names one or more distinct versions')
    if operation == 'floor':
        if not isinstance(change['min_version'], str) or not VERSION.fullmatch(change['min_version']):
            raise ValueError('Invalid min_version')


def next_contents(current, change, history=()):
    """(min_version, builds) after `change`; refuses a change the rules forbid.
    `history` is every earlier list: a build any of them listed, revoked or
    dropped since, is never added again."""
    check_change(change)
    operation = change['operation']
    if current is None:
        if operation != 'release':
            raise ValueError('The first list is a release list')
        return change['build']['version'], [change['build']]
    builds, floor = current['builds'], current['min_version']
    if operation == 'release':
        build = change['build']
        listed = [entry for entry in builds if entry['version'] == build['version']]
        if listed:
            if listed[0] != build:
                raise ValueError(f'Version {build["version"]} is already listed with another build')
            return floor, builds
        if version_key(build['version']) < version_key(floor):
            raise ValueError(f'Version {build["version"]} is below the list min_version {floor}')
        for document in history:
            for entry in document['builds']:
                if build['version'] == entry['version'] or build['code_directory_hash'] == entry['code_directory_hash']:
                    raise ValueError(f'Build {build["version"]} was listed before; a build is never listed again')
        return floor, builds + [build]
    if operation == 'republish':
        return floor, builds
    if operation == 'revoke':
        listed = {entry['version']: entry for entry in builds}
        for version in change['versions']:
            if version not in listed:
                raise ValueError(f'Version {version} is not listed')
            if listed[version]['revoked']:
                raise ValueError(f'Version {version} is already revoked')
        return floor, [dict(entry, revoked=True) if entry['version'] in change['versions'] else entry
                       for entry in builds]
    raised = change['min_version']
    if version_key(raised) <= version_key(floor):
        raise ValueError(f'min_version only rises: {raised} is not above {floor}')
    kept = [entry for entry in builds if version_key(entry['version']) >= version_key(raised)]
    if not kept:
        raise ValueError(f'min_version {raised} would drop every build')
    return raised, kept


def successor(current, change, now, history=()):
    """The next list: `change` applied, the next sequence number, an 8-day lifetime from now."""
    if current is not None and now < current['issued_at']:
        raise ValueError('The clock is behind the current list; refusing to move its dates back')
    floor, builds = next_contents(current, change, history)
    issued = int(now)
    document = {'v': 1, 'typ': DOCUMENT_TYPE, 'app_id': APP_ID, 'environment': ENVIRONMENT,
                'seq': 1 if current is None else current['seq'] + 1, 'issued_at': issued,
                'expires_at': issued + LIFETIME, 'min_version': floor, 'builds': builds}
    check_document(document)
    return document


def check_successor(current, document, change, history=()):
    """Refuse a document that is not exactly what `change` makes of `current`
    (the dates aside: issued no earlier than the current list, for 8 days)."""
    check_document(document)
    floor, builds = next_contents(current, change, history)
    expected_seq = 1 if current is None else current['seq'] + 1
    if document['seq'] != expected_seq:
        raise ValueError(f'The next list has sequence number {expected_seq}, not {document["seq"]}')
    if current is not None and document['issued_at'] < current['issued_at']:
        raise ValueError('The next list is issued before the current one')
    if document['expires_at'] - document['issued_at'] != LIFETIME:
        raise ValueError('The next list expires 8 days after its issue time')
    if document['min_version'] != floor:
        raise ValueError(f'The next list has min_version {floor}, not {document["min_version"]}')
    canonical = lambda entries: json.dumps(entries, separators=(',', ':'), sort_keys=True)
    if canonical(document['builds']) != canonical(builds):
        raise ValueError({'release': 'A release list adds exactly that release\'s build',
                          'republish': 'A re-publication keeps every build byte for byte',
                          'revoke': 'A revocation only flips the named builds to revoked',
                          'floor': 'A floor raise only drops the builds below it'}[change['operation']])


def check_fresh(document, now):
    """A prepared document is signed or published within 2 days of its issue time."""
    if document['issued_at'] > now + CLOCK_SKEW:
        raise ValueError('The list is issued in the future')
    if now - document['issued_at'] > MAXIMUM_SIGNING_DELAY:
        raise ValueError('The list was prepared more than 2 days ago; prepare it again')


def diff_lines(current, document):
    """The changes from `current` to `document`, one line each."""
    lines = []
    if current is None:
        lines.append(f'first list, min_version {document["min_version"]}')
        current = {'builds': [], 'min_version': document['min_version']}
    elif current['min_version'] != document['min_version']:
        lines.append(f'min_version {current["min_version"]} -> {document["min_version"]}')
    before = {entry['version']: entry for entry in current['builds']}
    after = {entry['version']: entry for entry in document['builds']}
    for version, entry in before.items():
        if version not in after:
            lines.append(f'- {version} {entry["code_directory_hash"]} (dropped below min_version)')
        elif after[version] != entry:
            lines.append(f'~ {version} {entry["code_directory_hash"]} revoked {entry["revoked"]} -> '
                         f'{after[version]["revoked"]}')
    for version, entry in after.items():
        if version not in before:
            lines.append(f'+ {version} code_directory_hash {entry["code_directory_hash"]} binary_sha256 '
                         f'{entry["binary_sha256"]} source_commit {entry["source_commit"]}')
    return lines or ['builds and min_version unchanged']


def schedule_state(document, now):
    """('ok' | 'due' | 'escalate', message) for the published list at `now`."""
    left = document['expires_at'] - int(now)
    if left <= ESCALATION_WINDOW:
        days = max(left, 0) // DAY
        return 'escalate', f'The published provider build list expires in {days} days; re-publish it'
    if int(now) - document['issued_at'] >= RESIGN_DUE_AGE:
        return 'due', 'The published provider build list is due to be re-signed'
    return 'ok', 'The published provider build list is current'


# The release bundle, recomputed (macOS).

def published_build(bundle, version, run=subprocess.run):
    """(code_directory_hash, binary_sha256) recomputed from a published release
    bundle with tar and codesign, after codesign verifies the app against the
    Developer ID requirement of our team."""
    import provider_release_identity
    names = provider_release_identity.github_env(version)
    with tempfile.TemporaryDirectory(prefix='provider-build-list-bundle-') as directory:
        # Native tar restores the signing extended attributes.
        run(['/usr/bin/tar', '-xzf', str(bundle), '-C', directory], check=True, timeout=600)
        app = Path(directory) / names['APP_NAME']
        requirement = (f'anchor apple generic and identifier "io.darkbloom.provider" and '
                       f'certificate leaf[subject.OU] = "{TEAM_ID}"')
        run(['codesign', '--verify', '--deep', '--strict', f'-R={requirement}', str(app)], check=True, timeout=600)
        display = run(['codesign', '-d', '--verbose=4', str(app / 'Contents/MacOS' / names['CLI_NAME'])],
                      capture_output=True, text=True, check=True, timeout=120)
        found = re.findall(r'(?m)^CandidateCDHashFull sha256=([0-9a-f]{64})$', display.stdout + display.stderr)
        if len(found) != 1:
            raise ValueError('codesign did not report one full SHA-256 CodeDirectory hash')
        with (Path(directory) / 'bin' / names['PRODUCT_CLI_NAME']).open('rb') as stream:
            binary = hashlib.file_digest(stream, 'sha256').hexdigest()
        return found[0], binary


# Publication: the rolling release that holds the lists.

def sequence_name(seq):
    return f'provider-builds-{seq}.jws'


def write_list(directory, document, jws):
    """The list under its fixed name and its sequence name, and the document beside them."""
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=False)
    (directory / DOCUMENT_NAME).write_bytes(document_bytes(document))
    for name in (LIST_NAME, sequence_name(document['seq'])):
        (directory / name).write_text(jws)


def published_lists(release, repository, run=subprocess.run):
    """[(seq, list)] of every numbered list asset of the release, by sequence
    number; [] when the release or its list assets are missing."""
    view = run(['gh', 'release', 'view', release, '--repo', repository, '--json', 'assets'],
               capture_output=True, text=True, timeout=120)
    if view.returncode != 0:
        if 'release not found' in view.stderr:
            return []
        raise RuntimeError('Could not read the release that holds the lists: ' + view.stderr.strip())
    numbers = sorted(int(match.group(1)) for asset in json.loads(view.stdout)['assets']
                     if (match := SEQUENCE_NAME.fullmatch(asset['name'])))
    if not numbers:
        return []
    with tempfile.TemporaryDirectory(prefix='provider-build-list-') as directory:
        run(['gh', 'release', 'download', release, '--repo', repository, '--pattern', 'provider-builds-*.jws',
             '--dir', directory], check=True, timeout=300)
        return [(seq, read_list(Path(directory) / sequence_name(seq))) for seq in numbers]


def newest_and_history(lists, keys, openssl, now):
    """(newest document, every document) of the published lists. The newest
    must verify with a pinned key and carry its asset's sequence number. The
    earlier ones only refuse builds that were listed before, so a list a
    rotated-out key signed still counts; one that does not parse stops here."""
    if not lists:
        return None, []
    documents = []
    for seq, jws in lists:
        document = unverified_document(jws)
        if document['seq'] != seq:
            raise ValueError(f'The asset {sequence_name(seq)} holds sequence {document["seq"]}')
        documents.append(document)
    seq, jws = lists[-1]
    newest = verify_list(jws, keys, openssl, now, allow_expired=True)
    return newest, documents


def allowed_url(address):
    parsed = urllib.parse.urlsplit(address)
    return parsed.scheme == 'https' and parsed.hostname in FETCH_HOSTS and parsed.port in (None, 443)


class OneAllowedRedirect(urllib.request.HTTPRedirectHandler):
    """At most one redirect, only to an allowed host, never carrying an Authorization header."""
    max_redirections = 1

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        if not allowed_url(newurl):
            raise ValueError(f'Refusing a redirect to {urllib.parse.urlsplit(newurl).hostname}')
        redirected = super().redirect_request(req, fp, code, msg, headers, newurl)
        if redirected is not None:
            redirected.remove_header('Authorization')
        return redirected


def fetch(url, limit=MAXIMUM_LIST_BYTES, timeout=60):
    """The bytes at an HTTPS URL on an allowed host, following at most one
    redirect, to an allowed host, with no Authorization header; None on 404."""
    if not allowed_url(url):
        raise ValueError(f'Refusing to fetch {url}: only HTTPS on ' + ', '.join(FETCH_HOSTS))
    try:
        with urllib.request.build_opener(OneAllowedRedirect()).open(url, timeout=timeout) as response:
            data = response.read(limit + 1)
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return None
        raise
    if len(data) > limit:
        raise ValueError(f'{url} is larger than {limit} bytes')
    return data
