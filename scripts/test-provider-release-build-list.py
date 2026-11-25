#!/usr/bin/env python3
"""The signed provider-build list: document, JWS, change rules and the workflows,
without credentials, network or uploads. Needs the OpenSSL 3 command line
(`OPENSSL`, else `openssl` on PATH)."""
import copy
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock
import urllib.request

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / 'scripts'))
import provider_release_build_list as lists  # noqa: E402

SPEC = importlib.util.spec_from_file_location('build_list_cli', ROOT / 'scripts/provider-release-build-list.py')
CLI = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CLI)

WORKFLOW = (ROOT / '.github/workflows/provider-release-build-list.yml').read_text()
OPENSSL = lists.OpenSSL()
NOW = 1796000000
REPOSITORY = 'Layr-Labs/d-inference'
TEST_KEYS = [(lists.key_id(lists.TEST_PUBLIC_KEY), lists.TEST_PUBLIC_KEY)]
PUBLISHED_LISTS = lists.published_lists

# RFC 8037 appendix A.3 and A.4: the RFC 8032 TEST 1 key's thumbprint, and its
# signature of an EdDSA JWS.
RFC_8037_THUMBPRINT = 'kPrK_qmxVWaYVA9wwBF6Iuo3vVzz7TxHCTwXBygrS4k'
RFC_8037_SIGNING_INPUT = b'eyJhbGciOiJFZERTQSJ9.RXhhbXBsZSBvZiBFZDI1NTE5IHNpZ25pbmc'
RFC_8037_SIGNATURE = 'hgyY0il_MGCjP0JzlnLWG1PPOt7-09PGcvMg3AIbQR6dWbhijcNR4ki4iylGjg5BhVsPt9g7sVvpAr_MuM0KAg'
# The dry-run current list, signed with the test key. Ed25519 is deterministic,
# so these bytes are fixed.
DRY_RUN_DOCUMENT_SHA256 = '3df0aac0462b2aef71ec3268b9d0accdfd78512cf1673de2461cc69dd58a9049'
DRY_RUN_LIST_SHA256 = '593845ed49acc47154033f50d4a0424d8949d10e8af95674d670ed99b5e1f9f0'


def build(version, seed, revoked=False):
    digest = hashlib.sha256(seed.encode()).hexdigest()
    return {'version': version, 'code_directory_hash': digest,
            'binary_sha256': hashlib.sha256(digest.encode()).hexdigest(),
            'source_commit': hashlib.sha1(seed.encode()).hexdigest(), 'revoked': revoked}


B18, B19, B20, B21 = (build(v, 'build-' + v) for v in ('0.10.18', '0.10.19', '0.10.20', '0.10.21'))


def document(seq=3, builds=(B18, B19), floor='0.10.18', issued=NOW - 3 * lists.DAY):
    return {'v': 1, 'typ': lists.DOCUMENT_TYPE, 'app_id': lists.APP_ID, 'environment': lists.ENVIRONMENT,
            'seq': seq, 'issued_at': issued, 'expires_at': issued + lists.LIFETIME, 'min_version': floor,
            'builds': [dict(entry) for entry in builds]}


class Signer:
    """A non-test key, as a production signer would hold."""
    name = 'other'

    def __init__(self, seed=None):
        self.seed = seed or os.urandom(32)
        self.public_key = OPENSSL.public_key(self.seed)

    def sign(self, message):
        return OPENSSL.sign(self.seed, message)

    def keys(self):
        return [(lists.key_id(self.public_key), self.public_key)]


class Vectors(unittest.TestCase):
    def test_test_key_is_rfc_8032_test_1_and_signs_rfc_8037_vectors(self):
        signer = lists.TestSigner(OPENSSL)
        self.assertEqual(signer.public_key.hex(), 'd75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a')
        self.assertEqual(lists.key_id(signer.public_key), RFC_8037_THUMBPRINT)
        self.assertEqual(lists.b64url(signer.sign(RFC_8037_SIGNING_INPUT)), RFC_8037_SIGNATURE)
        self.assertTrue(OPENSSL.verify(signer.public_key, RFC_8037_SIGNING_INPUT, lists.unb64url(RFC_8037_SIGNATURE)))
        self.assertFalse(OPENSSL.verify(signer.public_key, RFC_8037_SIGNING_INPUT + b'x',
                                        lists.unb64url(RFC_8037_SIGNATURE)))

    def test_header_and_document_bytes_are_exact(self):
        self.assertEqual(lists.protected_header(RFC_8037_THUMBPRINT),
                         b'{"alg":"Ed25519","kid":"kPrK_qmxVWaYVA9wwBF6Iuo3vVzz7TxHCTwXBygrS4k",'
                         b'"typ":"darkbloom-provider-builds+jws"}')
        entry = {'revoked': False, 'source_commit': 'a' * 40, 'binary_sha256': 'b' * 64,
                 'code_directory_hash': 'c' * 64, 'version': '0.10.20'}
        shuffled = {'builds': [entry], 'min_version': '0.10.20', 'expires_at': 1700691200, 'issued_at': 1700000000,
                    'seq': 7, 'environment': 'production', 'app_id': lists.APP_ID, 'typ': lists.DOCUMENT_TYPE, 'v': 1}
        self.assertEqual(lists.document_bytes(shuffled),
                         b'{"v":1,"typ":"darkbloom-provider-builds","app_id":"SLDQ2GJ6TL.io.darkbloom.provider",'
                         b'"environment":"production","seq":7,"issued_at":1700000000,"expires_at":1700691200,'
                         b'"min_version":"0.10.20","builds":[{"version":"0.10.20","code_directory_hash":"' +
                         b'c' * 64 + b'","binary_sha256":"' + b'b' * 64 + b'","source_commit":"' + b'a' * 40 +
                         b'","revoked":false}]}')

    def test_the_dry_run_list_is_fixed(self):
        dry_run = json.loads(lists.DRY_RUN_DOCUMENT.read_text())
        self.assertEqual(lists.document_sha256(dry_run), DRY_RUN_DOCUMENT_SHA256)
        jws = lists.sign_list(dry_run, lists.TestSigner(OPENSSL))
        self.assertEqual(hashlib.sha256(jws.encode()).hexdigest(), DRY_RUN_LIST_SHA256)
        self.assertEqual(lists.unb64url(jws.split('.')[0]), lists.protected_header(RFC_8037_THUMBPRINT))
        self.assertEqual(lists.unb64url(jws.split('.')[1]), lists.document_bytes(dry_run))

    def test_openssl_must_be_version_3(self):
        with tempfile.TemporaryDirectory() as directory:
            fake = Path(directory) / 'openssl'
            fake.write_text('#!/bin/sh\necho "LibreSSL 3.3.6"\n')
            fake.chmod(0o755)
            with self.assertRaisesRegex(RuntimeError, 'OpenSSL 3 or later'):
                lists.OpenSSL(str(fake))


class Documents(unittest.TestCase):
    def test_canonical_documents_round_trip(self):
        data = lists.document_bytes(document())
        self.assertEqual(lists.document_bytes(lists.parse_document(data)), data)

    def test_other_encodings_are_refused(self):
        data = lists.document_bytes(document())
        for label, variant in (('spaces', data.replace(b',', b', ')), ('newline', data + b'\n'),
                               ('duplicate key', data.replace(b'{"v":1,', b'{"v":1,"v":1,')),
                               ('reordered', data.replace(b'"v":1,"typ"', b'"typ"').replace(
                                   b'"darkbloom-provider-builds",', b'"darkbloom-provider-builds","v":1,', 1)),
                               ('escaped', data.replace(b'production', b'producti\\u006fn'))):
            with self.subTest(variant=label), self.assertRaises(ValueError):
                lists.parse_document(variant)

    def test_invalid_documents_are_refused(self):
        def mutated(change):
            value = document()
            change(value)
            return value
        cases = {
            'extra field': lambda d: d.update(extra=1),
            'missing floor': lambda d: d.pop('min_version'),
            'version 2': lambda d: d.update(v=2),
            'another app': lambda d: d.update(app_id='SLDQ2GJ6TL.io.example'),
            'development': lambda d: d.update(environment='development'),
            'another type': lambda d: d.update(typ='darkbloom-gateway-measurements'),
            'seq 0': lambda d: d.update(seq=0),
            'seq true': lambda d: d.update(seq=True),
            'seq float': lambda d: d.update(seq=3.0),
            'lifetime over 8 days': lambda d: d.update(expires_at=d['issued_at'] + lists.LIFETIME + 1),
            'expires at issue': lambda d: d.update(expires_at=d['issued_at']),
            'no builds': lambda d: d.update(builds=[]),
            'build below the floor': lambda d: d.update(min_version='0.10.19'),
            'floor with a suffix': lambda d: d.update(min_version='0.10.18-dev.1'),
            'build version with a suffix': lambda d: d['builds'][0].update(version='0.10.18-dev.1'),
            'leading zero': lambda d: d['builds'][0].update(version='0.10.018'),
            'upper-case hash': lambda d: d['builds'][0].update(code_directory_hash='A' * 64),
            'short hash': lambda d: d['builds'][0].update(binary_sha256='a' * 63),
            'short commit': lambda d: d['builds'][0].update(source_commit='a' * 39),
            'revoked 0': lambda d: d['builds'][0].update(revoked=0),
            'build extra field': lambda d: d['builds'][0].update(note='x'),
            'duplicate version': lambda d: d['builds'][1].update(version='0.10.18'),
            'duplicate hash': lambda d: d['builds'][1].update(code_directory_hash=B18['code_directory_hash']),
            'shared 20-byte prefix': lambda d: d['builds'][1].update(
                code_directory_hash=B18['code_directory_hash'][:40] + 'f' * 24),
        }
        for label, change in cases.items():
            with self.subTest(case=label), self.assertRaises(ValueError):
                lists.document_bytes(mutated(change))


class Lists(unittest.TestCase):
    def setUp(self):
        self.signer = Signer()
        self.document = document()
        self.jws = lists.sign_list(self.document, self.signer)

    def test_a_signed_list_verifies_with_its_pinned_key(self):
        self.assertEqual(lists.verify_list(self.jws, self.signer.keys(), OPENSSL, NOW), self.document)
        two = Signer().keys() + self.signer.keys()
        self.assertEqual(lists.verify_list(self.jws, two, OPENSSL, NOW), self.document)

    def test_anything_else_is_refused(self):
        header, payload, signature = self.jws.split('.')
        kid = lists.key_id(self.signer.public_key)
        other_header = lists.b64url(b'{"alg":"EdDSA","kid":"%s","typ":"darkbloom-provider-builds+jws"}' % kid.encode())
        spaced_header = lists.b64url(lists.protected_header(kid).replace(b',', b', '))
        tampered = dict(self.document, seq=4)
        flipped = signature[:-2] + ('A' if signature[-2] != 'A' else 'B') + signature[-1]
        cases = {
            'unpinned key': (self.jws, Signer().keys()),
            'no pinned key': (self.jws, []),
            'alg EdDSA': ('.'.join([other_header, payload, signature]), self.signer.keys()),
            'header spacing': ('.'.join([spaced_header, payload, signature]), self.signer.keys()),
            'payload changed': ('.'.join([header, lists.b64url(lists.document_bytes(tampered)), signature]),
                                self.signer.keys()),
            'signature changed': ('.'.join([header, payload, flipped]), self.signer.keys()),
            'padded': (self.jws + '=', self.signer.keys()),
            'trailing newline': (self.jws + '\n', self.signer.keys()),
            'two parts': (header + '.' + payload, self.signer.keys()),
            'standard base64': (self.jws.replace('-', '+', 1) if '-' in self.jws else self.jws + '+',
                                self.signer.keys()),
        }
        for label, (jws, keys) in cases.items():
            with self.subTest(case=label), self.assertRaises(ValueError):
                lists.verify_list(jws, keys, OPENSSL, NOW)

    def test_expiry_and_the_sequence_floor(self):
        expired = NOW + lists.LIFETIME
        with self.assertRaisesRegex(ValueError, 'expired'):
            lists.verify_list(self.jws, self.signer.keys(), OPENSSL, expired)
        self.assertEqual(lists.verify_list(self.jws, self.signer.keys(), OPENSSL, expired, allow_expired=True),
                         self.document)
        with self.assertRaisesRegex(ValueError, 'below 4'):
            lists.verify_list(self.jws, self.signer.keys(), OPENSSL, NOW, minimum_seq=4)

    def test_the_signer_limit(self):
        self.assertIsNone(lists.size_warning(self.document))
        size = len(lists.signing_input(self.document, lists.key_id(self.signer.public_key)))
        with mock.patch.object(lists, 'SIGNING_INPUT_LIMIT', size * 2 - 1):
            self.assertIn('half of the signer', lists.size_warning(self.document))
        with mock.patch.object(lists, 'SIGNING_INPUT_LIMIT', size - 1):
            with self.assertRaisesRegex(ValueError, 'over the signer'):
                lists.sign_list(self.document, self.signer)


class Keys(unittest.TestCase):
    def test_the_pinned_key_file_never_lists_the_test_key(self):
        keys = lists.load_keys()
        self.assertLessEqual(len(keys), lists.MAXIMUM_KEYS)
        self.assertNotIn(lists.TEST_PUBLIC_KEY, [public for _, public in keys])
        self.assertNotIn(lists.key_id(lists.TEST_PUBLIC_KEY), lists.PINNED_KEYS.read_text())

    def test_key_files_are_checked(self):
        good = json.loads(lists.keys_text([Signer().public_key]))['keys'][0]
        cases = {
            'three keys': {'keys': json.loads(lists.keys_text([Signer().public_key for _ in range(3)]))['keys']},
            'wrong kid': {'keys': [dict(good, kid=RFC_8037_THUMBPRINT)]},
            'short key': {'keys': [{'kid': lists.key_id(b'x' * 31), 'public_key': 'eHh4' * 10 + 'eA=='}]},
            'url-safe base64': {'keys': [dict(good, public_key=good['public_key'].replace('+', '-').replace('/', '_'))]}
            if ('+' in good['public_key'] or '/' in good['public_key']) else {'keys': [dict(good, extra=1)]},
            'duplicate': {'keys': [good, good]},
            'not an object': [good],
        }
        for label, content in cases.items():
            with self.subTest(case=label), tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / 'keys.json'
                path.write_text(json.dumps(content))
                with self.assertRaises((ValueError, Exception)):
                    lists.load_keys(path)


class Changes(unittest.TestCase):
    def setUp(self):
        self.current = document()

    def successor(self, change, history=()):
        return lists.successor(self.current, change, NOW, history)

    def test_a_release_adds_exactly_its_build(self):
        first = lists.successor(None, {'operation': 'release', 'build': B20}, NOW)
        self.assertEqual((first['seq'], first['min_version'], first['builds']), (1, '0.10.20', [B20]))
        self.assertEqual(first['expires_at'] - first['issued_at'], lists.LIFETIME)
        after = self.successor({'operation': 'release', 'build': B20})
        self.assertEqual((after['seq'], after['min_version'], after['builds']), (4, '0.10.18', [B18, B19, B20]))
        self.assertEqual(after['issued_at'], NOW)
        # A retried publication of the same release changes nothing else.
        self.assertEqual(self.successor({'operation': 'release', 'build': B19})['builds'], [B18, B19])

    def test_a_release_never_changes_or_relists_a_build(self):
        cases = {
            'listed with another build': (dict(B19, binary_sha256='e' * 64), ()),
            'below the floor': (build('0.10.17', 'old'), ()),
            'revoked build': (dict(B20, revoked=True), ()),
            'version listed before': (B20, [document(builds=[B20], floor='0.10.20')]),
            'digest listed before': (dict(B21, code_directory_hash=B20['code_directory_hash']),
                                     [document(builds=[B20], floor='0.10.20')]),
        }
        for label, (entry, history) in cases.items():
            with self.subTest(case=label), self.assertRaises(ValueError):
                self.successor({'operation': 'release', 'build': entry}, history)
        with self.assertRaisesRegex(ValueError, 'first list'):
            lists.successor(None, {'operation': 'republish'}, NOW)

    def test_a_republication_keeps_builds_and_floor(self):
        self.current['builds'][0]['revoked'] = True
        after = self.successor({'operation': 'republish'})
        self.assertEqual((after['seq'], after['min_version'], after['builds']), (4, '0.10.18', self.current['builds']))
        with self.assertRaisesRegex(ValueError, 'behind'):
            lists.successor(self.current, {'operation': 'republish'}, self.current['issued_at'] - 1)

    def test_a_revocation_only_flips_named_builds(self):
        after = self.successor({'operation': 'revoke', 'versions': ['0.10.19']})
        self.assertEqual(after['builds'], [B18, dict(B19, revoked=True)])
        for versions in (['0.10.20'], [], ['0.10.19', '0.10.19'], ['latest']):
            with self.subTest(versions=versions), self.assertRaises(ValueError):
                self.successor({'operation': 'revoke', 'versions': versions})
        self.current = after
        with self.assertRaisesRegex(ValueError, 'already revoked'):
            self.successor({'operation': 'revoke', 'versions': ['0.10.19']})

    def test_a_floor_rises_and_drops_only_the_builds_below_it(self):
        after = self.successor({'operation': 'floor', 'min_version': '0.10.19'})
        self.assertEqual((after['min_version'], after['builds']), ('0.10.19', [B19]))
        for floor in ('0.10.18', '0.10.17', '0.10.20'):
            with self.subTest(floor=floor), self.assertRaises(ValueError):
                self.successor({'operation': 'floor', 'min_version': floor})

    def test_check_successor_refuses_every_other_document(self):
        release = {'operation': 'release', 'build': B20}
        republish = {'operation': 'republish'}
        expected = self.successor(release)
        lists.check_successor(self.current, expected, release)

        def variant(base, change):
            value = copy.deepcopy(base)
            change(value)
            return value
        republished = self.successor(republish)
        lists.check_successor(self.current, republished, republish)
        cases = [
            ('release adds two', release, variant(expected, lambda d: d['builds'].append(B21))),
            ('release drops one', release, variant(expected, lambda d: d['builds'].pop(0))),
            ('release reorders', release, variant(expected, lambda d: d['builds'].reverse())),
            ('release un-revokes', release, variant(expected, lambda d: d['builds'][0].update(revoked=True))),
            ('release edits a hash', release, variant(expected, lambda d: d['builds'][0].update(binary_sha256='e' * 64))),
            ('republish adds', republish, variant(republished, lambda d: d['builds'].append(B20))),
            ('republish drops', republish, variant(republished, lambda d: d['builds'].pop())),
            ('republish revokes', republish, variant(republished, lambda d: d['builds'][1].update(revoked=True))),
            ('republish raises the floor', republish, variant(republished, lambda d: (
                d.update(min_version='0.10.19'), d['builds'].pop(0)))),
            ('seq skips', republish, variant(republished, lambda d: d.update(seq=5))),
            ('seq repeats', republish, variant(republished, lambda d: d.update(seq=3))),
            ('short lifetime', republish, variant(republished, lambda d: d.update(expires_at=d['issued_at'] + 60))),
            ('issued earlier', republish, variant(republished, lambda d: d.update(
                issued_at=self.current['issued_at'] - 10, expires_at=self.current['issued_at'] - 10 + lists.LIFETIME))),
        ]
        for label, change, candidate in cases:
            with self.subTest(case=label), self.assertRaises(ValueError):
                lists.check_successor(self.current, candidate, change)

    def test_freshness_and_schedule(self):
        lists.check_fresh(document(issued=NOW - lists.DAY), NOW)
        with self.assertRaisesRegex(ValueError, 'prepare it again'):
            lists.check_fresh(document(issued=NOW - lists.MAXIMUM_SIGNING_DELAY - 1), NOW)
        with self.assertRaisesRegex(ValueError, 'future'):
            lists.check_fresh(document(issued=NOW + lists.CLOCK_SKEW + 1), NOW)
        self.assertEqual(lists.schedule_state(document(issued=NOW - 4 * lists.DAY + 1), NOW)[0], 'ok')
        self.assertEqual(lists.schedule_state(document(issued=NOW - 4 * lists.DAY), NOW)[0], 'due')
        self.assertEqual(lists.schedule_state(document(issued=NOW - 6 * lists.DAY + 1), NOW)[0], 'due')
        state, message = lists.schedule_state(document(issued=NOW - 6 * lists.DAY), NOW)
        self.assertEqual((state, message),
                         ('escalate', 'The published provider build list expires in 2 days; re-publish it'))
        self.assertEqual(lists.schedule_state(document(issued=NOW - 9 * lists.DAY), NOW)[0], 'escalate')

    def test_the_diff_names_every_change(self):
        revoked = self.successor({'operation': 'revoke', 'versions': ['0.10.18']})
        self.assertEqual(lists.diff_lines(self.current, revoked),
                         [f'~ 0.10.18 {B18["code_directory_hash"]} revoked False -> True'])
        floor = self.successor({'operation': 'floor', 'min_version': '0.10.19'})
        self.assertEqual(lists.diff_lines(self.current, floor)[:2],
                         ['min_version 0.10.18 -> 0.10.19',
                          f'- 0.10.18 {B18["code_directory_hash"]} (dropped below min_version)'])
        added = self.successor({'operation': 'release', 'build': B20})
        self.assertEqual(lists.diff_lines(self.current, added),
                         [f'+ 0.10.20 code_directory_hash {B20["code_directory_hash"]} binary_sha256 '
                          f'{B20["binary_sha256"]} source_commit {B20["source_commit"]}'])


class Fetch(unittest.TestCase):
    def test_only_https_on_the_two_hosts(self):
        for url in ('http://github.com/x', 'https://example.com/x', 'https://github.com:8443/x',
                    'https://objects.githubusercontent.com/x', 'https://github.com.example.com/x'):
            with self.subTest(url=url), self.assertRaises(ValueError):
                lists.fetch(url)

    def test_one_redirect_to_an_allowed_host_without_authorization(self):
        handler = lists.OneAllowedRedirect()
        self.assertEqual(handler.max_redirections, 1)
        request = urllib.request.Request('https://github.com/a/b/releases/download/t/provider-builds.jws',
                                         headers={'Authorization': 'token secret'})
        redirected = handler.redirect_request(request, io.BytesIO(), 302, 'Found', {},
                                              'https://release-assets.githubusercontent.com/github-production-release-asset/1')
        self.assertIsNone(redirected.get_header('Authorization'))
        with self.assertRaisesRegex(ValueError, 'objects.githubusercontent.com'):
            handler.redirect_request(request, io.BytesIO(), 302, 'Found', {},
                                     'https://objects.githubusercontent.com/x')


class FakeGitHub:
    """`gh release` for one release that holds numbered list assets."""

    def __init__(self, assets=None, missing=False):
        self.assets = dict(assets or {})
        self.missing = missing
        self.commands = []

    def __call__(self, command, **kwargs):
        self.commands.append(command)
        if command[:3] == ['gh', 'release', 'view']:
            if self.missing:
                return SimpleNamespace(returncode=1, stdout='', stderr='release not found')
            return SimpleNamespace(returncode=0, stderr='',
                                   stdout=json.dumps({'assets': [{'name': name} for name in self.assets]}))
        if command[:3] == ['gh', 'release', 'download']:
            pattern = command[command.index('--pattern') + 1]
            target = Path(command[command.index('--dir') + 1])
            for name, text in self.assets.items():
                if re.fullmatch(pattern.replace('.', r'\.').replace('*', '.*'), name):
                    (target / name).write_text(text)
            return SimpleNamespace(returncode=0)
        if command[:3] == ['gh', 'release', 'upload']:
            path = Path(command[4])
            if path.name in self.assets and '--clobber' not in command:
                raise subprocess.CalledProcessError(1, command)
            self.assets[path.name] = path.read_text()
            return SimpleNamespace(returncode=0)
        raise AssertionError(command)


class Published(unittest.TestCase):
    def test_published_lists_and_history(self):
        signer = Signer()
        first, second = document(seq=1, builds=[B18]), document(seq=2)
        github = FakeGitHub({lists.sequence_name(1): lists.sign_list(first, Signer()),
                             lists.sequence_name(2): lists.sign_list(second, signer),
                             lists.LIST_NAME: 'alias', 'other.txt': 'x'})
        found = lists.published_lists('provider-builds', REPOSITORY, github)
        self.assertEqual([seq for seq, _ in found], [1, 2])
        # The earlier list's key is no longer pinned: it still refuses re-adds.
        newest, history = lists.newest_and_history(found, signer.keys(), OPENSSL, NOW)
        self.assertEqual((newest, history), (second, [first, second]))
        with self.assertRaisesRegex(ValueError, 'pinned'):
            lists.newest_and_history(found[:1], signer.keys(), OPENSSL, NOW)
        renamed = [(3, found[1][1])]
        with self.assertRaisesRegex(ValueError, 'holds sequence 2'):
            lists.newest_and_history(renamed, signer.keys(), OPENSSL, NOW)
        self.assertEqual(lists.published_lists('provider-builds', REPOSITORY, FakeGitHub(missing=True)), [])

    def test_published_build_recomputes_from_the_bundle(self):
        commands = []

        def run(command, **kwargs):
            commands.append(command)
            if command[0] == '/usr/bin/tar':
                root = Path(command[command.index('-C') + 1])
                (root / 'bin').mkdir()
                (root / 'bin/darkbloom').write_bytes(b'binary')
            if command[:2] == ['codesign', '-d']:
                return SimpleNamespace(stdout='', stderr='Executable=x\nCandidateCDHashFull sha256=' + 'c' * 64 + '\n')
            return SimpleNamespace(stdout='', stderr='')
        self.assertEqual(lists.published_build('bundle.tar.gz', '0.10.20', run),
                         ('c' * 64, hashlib.sha256(b'binary').hexdigest()))
        verify = commands[1]
        self.assertEqual(verify[:4], ['codesign', '--verify', '--deep', '--strict'])
        self.assertEqual(verify[4], '-R=anchor apple generic and identifier "io.darkbloom.provider" and '
                                    'certificate leaf[subject.OU] = "SLDQ2GJ6TL"')
        self.assertTrue(verify[5].endswith('/Darkbloom.app'))
        self.assertTrue(commands[2][-1].endswith('/Darkbloom.app/Contents/MacOS/darkbloom'))


class CommandLine(unittest.TestCase):
    """The script's commands end to end, with `gh` faked."""

    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='build-list-test-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        environment = {'GITHUB_REPOSITORY': REPOSITORY, 'GITHUB_OUTPUT': str(self.root / 'output'),
                       'GITHUB_STEP_SUMMARY': str(self.root / 'summary')}
        patcher = mock.patch.dict(os.environ, environment)
        patcher.start()
        self.addCleanup(patcher.stop)

    def cli(self, *argv):
        with mock.patch('sys.stdout', io.StringIO()) as out:
            code = CLI.main([str(value) for value in argv])
        return code, out.getvalue()

    def output(self, name):
        return dict(line.split('=', 1) for line in (self.root / 'output').read_text().splitlines())[name]

    def dry_run(self, operation, *change):
        seed, prepared, signed = self.root / 'seed', self.root / 'prepared', self.root / 'signed'
        self.cli('dry-run-seed', '--output', seed)
        self.cli('prepare', operation, *change, '--seed', seed, '--output', prepared)
        digest = self.output('document_sha256')
        self.cli('sign', operation, *change, '--prepared', prepared, '--document-sha256', digest, '--dry-run',
                 '--signer', 'test', '--output', signed)
        _, plan = self.cli('publish', operation, *change, '--prepared', prepared, '--document-sha256', digest,
                           '--dry-run', '--list-dir', signed)
        return prepared, signed, digest, plan

    def test_dry_run_republication(self):
        prepared, signed, digest, plan = self.dry_run('republish')
        self.assertEqual(hashlib.sha256((prepared / 'provider-builds.json').read_bytes()).hexdigest(), digest)
        jws = (signed / lists.LIST_NAME).read_text()
        self.assertEqual((signed / 'provider-builds-2.jws').read_text(), jws)
        signed_document = lists.verify_list(jws, TEST_KEYS, OPENSSL, lists.unverified_document(jws)['issued_at'])
        self.assertEqual(signed_document['builds'], json.loads(lists.DRY_RUN_DOCUMENT.read_text())['builds'])
        self.assertIn('nothing is uploaded', plan)
        self.assertRegex(plan, r'gh release upload provider-builds \S+/provider-builds-2\.jws --repo '
                               r'Layr-Labs/d-inference\n')
        self.assertIn('/provider-builds.jws --repo Layr-Labs/d-inference --clobber', plan)
        self.assertLess(plan.index('provider-builds-2.jws'), plan.index('--clobber'))
        # No pinned key verifies a test list.
        with self.assertRaisesRegex(ValueError, 'pinned key ID'):
            lists.verify_list(jws, lists.load_keys(), OPENSSL, signed_document['issued_at'])

    def test_dry_run_revocation_and_floor(self):
        _, signed, _, _ = self.dry_run('revoke', '--versions', '0.10.18')
        builds = lists.unverified_document((signed / lists.LIST_NAME).read_text())['builds']
        self.assertEqual([entry['revoked'] for entry in builds], [True, False])
        for directory in ('seed', 'prepared', 'signed'):
            for path in sorted((self.root / directory).iterdir(), reverse=True):
                path.unlink()
            (self.root / directory).rmdir()
        _, signed, _, _ = self.dry_run('floor', '--min-version', '0.10.19')
        listed = lists.unverified_document((signed / lists.LIST_NAME).read_text())
        self.assertEqual((listed['min_version'], [entry['version'] for entry in listed['builds']]),
                         ('0.10.19', ['0.10.19']))

    def publication(self, version='0.10.20', production=True):
        """A digest-checked publication artifact, as the release lane downloads it."""
        directory = self.root / 'publication'
        directory.mkdir()
        (directory / 'darkbloom-bundle-macos-arm64.tar.gz').write_bytes(b'bundle')
        payload = {'version': version, 'source_commit': B20['source_commit'], 'ci_run_id': '77',
                   'binary_hash': B20['binary_sha256'], 'code_directory_hash': B20['code_directory_hash'],
                   'bundle_hash': hashlib.sha256(b'bundle').hexdigest(),
                   'require_app_attest_qualification': production}
        provenance = {'source_commit': B20['source_commit'], 'signing_run_id': '77'}
        (directory / 'release-payload.json').write_text(json.dumps(payload))
        (directory / 'release-provenance.json').write_text(json.dumps(provenance))
        os.environ.update({
            'RELEASE_PAYLOAD_SHA256': hashlib.sha256((directory / 'release-payload.json').read_bytes()).hexdigest(),
            'RELEASE_PROVENANCE_SHA256': hashlib.sha256((directory / 'release-provenance.json').read_bytes()).hexdigest(),
            'RELEASE_SOURCE_SHA': B20['source_commit'], 'RELEASE_SIGNING_RUN_ID': '77', 'VERSION': version})
        return directory

    def test_release_lane_dry_run_starts_the_first_list(self):
        publication, prepared, signed = self.publication(), self.root / 'prepared', self.root / 'signed'
        with mock.patch.object(lists, 'published_lists', return_value=[]):
            self.cli('prepare', 'release', '--publication', publication, '--output', prepared)
            digest = self.output('document_sha256')
            self.cli('sign', 'release', '--publication', publication, '--prepared', prepared, '--document-sha256',
                     digest, '--dry-run', '--signer', 'test', '--output', signed)
        listed = lists.unverified_document((signed / lists.LIST_NAME).read_text())
        self.assertEqual((listed['seq'], listed['min_version'], listed['builds']), (1, '0.10.20', [B20]))
        self.assertFalse((prepared / 'current.jws').exists())

    def test_release_payload_must_be_production_and_unchanged(self):
        publication = self.publication(production=False)
        with mock.patch.object(lists, 'published_lists', return_value=[]), \
                self.assertRaisesRegex(ValueError, 'Only a production release'):
            self.cli('prepare', 'release', '--publication', publication, '--output', self.root / 'prepared')
        (publication / 'release-payload.json').write_text('{}')
        with mock.patch.object(lists, 'published_lists', return_value=[]), \
                self.assertRaisesRegex(ValueError, 'digest mismatch'):
            self.cli('prepare', 'release', '--publication', publication, '--output', self.root / 'prepared2')

    def test_sign_checks_the_digest_and_the_published_bundle(self):
        publication, prepared, signed = self.publication(), self.root / 'prepared', self.root / 'signed'
        with mock.patch.object(lists, 'published_lists', return_value=[]):
            self.cli('prepare', 'release', '--publication', publication, '--output', prepared)
        digest = self.output('document_sha256')
        common = ['sign', 'release', '--prepared', prepared, '--dry-run', '--signer', 'test']
        with self.assertRaisesRegex(ValueError, 'given SHA-256'):
            self.cli(*common, '--publication', publication, '--document-sha256', 'f' * 64, '--output', signed)
        # Off CI the signer has no publication artifact: the bundle decides.
        with mock.patch.object(lists, 'published_build', return_value=('e' * 64, B20['binary_sha256'])), \
                self.assertRaisesRegex(ValueError, 'differs from the list entry'):
            self.cli(*common, '--version', '0.10.20', '--bundle', 'bundle', '--document-sha256', digest,
                     '--output', signed)
        with mock.patch.object(lists, 'published_build',
                               return_value=(B20['code_directory_hash'], B20['binary_sha256'])):
            self.cli(*common, '--version', '0.10.20', '--bundle', 'bundle', '--document-sha256', digest,
                     '--output', signed)
        # Any signer but the test key recomputes the build from the bundle.
        args = SimpleNamespace(operation='release', prepared=prepared, document_sha256=digest, dry_run=True,
                               signer='other', bundle=None, publication=None, version='0.10.20',
                               output=self.root / 'signed2', keys=lists.PINNED_KEYS)
        with mock.patch.object(lists, 'signer', return_value=Signer()), \
                self.assertRaisesRegex(ValueError, 'recomputes the build'):
            CLI.sign(args, OPENSSL, lists.unverified_document(
                (signed / lists.LIST_NAME).read_text())['issued_at'])

    def test_publish_refuses_a_test_or_unpinned_list(self):
        prepared, signed, digest, _ = self.dry_run('republish')
        common = ['publish', 'republish', '--prepared', prepared, '--document-sha256', digest, '--list-dir', signed]
        pinned_test_key = self.root / 'test-key.json'
        pinned_test_key.write_text(lists.keys_text([lists.TEST_PUBLIC_KEY]))
        with mock.patch.object(lists, 'published_lists', side_effect=AssertionError('no fetch')):
            with self.assertRaisesRegex(ValueError, 'pinned key ID'):
                self.cli(*common)
            with self.assertRaisesRegex(ValueError, 'test key never publishes'):
                self.cli(*common, '--keys', pinned_test_key)

    def test_publish_uploads_the_numbered_list_first(self):
        signer = Signer()
        keys = self.root / 'pinned.json'
        keys.write_text(lists.keys_text([signer.public_key]))
        current = document(seq=3, issued=NOW - 5 * lists.DAY)
        current_jws = lists.sign_list(current, signer)
        github = FakeGitHub({lists.sequence_name(3): current_jws, lists.LIST_NAME: current_jws})
        prepared, signed = self.root / 'prepared', self.root / 'signed'
        prepared.mkdir()
        nxt = lists.successor(current, {'operation': 'republish'}, NOW - 60)
        (prepared / 'provider-builds.json').write_bytes(lists.document_bytes(nxt))
        (prepared / 'current.jws').write_text(current_jws)
        jws = lists.sign_list(nxt, signer)
        lists.write_list(signed, nxt, jws)
        digest = lists.document_sha256(nxt)
        args = SimpleNamespace(operation='republish', prepared=prepared, document_sha256=digest, dry_run=False,
                               list_dir=signed, release='provider-builds', keys=keys)
        with mock.patch.object(lists, 'published_lists', lambda release, repository: PUBLISHED_LISTS(
                release, repository, github)), mock.patch('sys.stdout', io.StringIO()):
            CLI.publish(args, OPENSSL, NOW, run=github)
        uploads = [command for command in github.commands if command[:3] == ['gh', 'release', 'upload']]
        self.assertEqual([Path(command[4]).name for command in uploads], ['provider-builds-4.jws', 'provider-builds.jws'])
        self.assertNotIn('--clobber', uploads[0])
        self.assertIn('--clobber', uploads[1])
        self.assertEqual(github.assets[lists.LIST_NAME], jws)
        # Again: the numbered list now exists, so the newest list is no longer
        # the one the document was prepared from.
        with mock.patch.object(lists, 'published_lists', lambda release, repository: PUBLISHED_LISTS(
                release, repository, github)), self.assertRaisesRegex(ValueError, 'prepare again'):
            CLI.publish(args, OPENSSL, NOW, run=github)

    def test_check_states(self):
        signer = Signer()
        keys = self.root / 'pinned.json'
        keys.write_text(lists.keys_text([signer.public_key]))
        url = 'https://github.com/Layr-Labs/d-inference/releases/download/provider-builds/provider-builds.jws'
        code, out = self.cli('check', '--url', url)
        self.assertEqual((code, self.output('state')), (0, 'none'))
        cases = ((NOW - 3 * lists.DAY, 0, 'ok'), (NOW - 4 * lists.DAY, 0, 'due'), (NOW - 6 * lists.DAY, 1, 'escalate'))
        for issued, expected_code, state in cases:
            jws = lists.sign_list(document(issued=issued), signer)
            with self.subTest(state=state), mock.patch.object(lists, 'fetch', return_value=jws.encode()), \
                    mock.patch.object(CLI.time, 'time', return_value=NOW):
                (self.root / 'output').unlink()
                code, out = self.cli('check', '--url', url, '--keys', keys)
                self.assertEqual((code, self.output('state')), (expected_code, state))
        with mock.patch.object(lists, 'fetch', return_value=None):
            self.assertEqual(self.cli('check', '--url', url, '--keys', keys)[0], 1)
        with mock.patch.object(lists, 'fetch', return_value=lists.sign_list(document(), Signer()).encode()):
            code, out = self.cli('check', '--url', url, '--keys', keys)
            self.assertEqual(code, 1)
            self.assertIn('does not verify', out)


def jobs(text):
    body = text.split('\njobs:\n', 1)[1]
    parts = re.split(r'(?m)^  ([a-z][a-z0-9_-]*):\n', body)
    return dict(zip(parts[1::2], parts[2::2]))


def code(text):
    return re.sub(r'(?m)^\s*#.*\n', '', text)


class Workflows(unittest.TestCase):
    def test_the_list_workflow_holds_no_credential_and_publishes_nothing(self):
        text = code(WORKFLOW)
        self.assertIn('\npermissions: {}\n', text)
        for forbidden in ('secrets.', 'id-token', 'environment:', 'contents: write', 'pull_request'):
            self.assertNotIn(forbidden, text)
        self.assertEqual(set(re.findall(r'--signer (\S+)', text)), {'test'})
        invocations = re.findall(r'provider-release-build-list\.py (?:sign|publish)[^\n]*(?:\n +--[^\n]*)*', text)
        self.assertEqual(len(invocations), 2)
        for invocation in invocations:
            with self.subTest(invocation=invocation.split('\n')[0]):
                self.assertIn('--dry-run', invocation)
        self.assertNotRegex(text, r'gh release (upload|create|edit|delete)')
        for action in re.findall(r'uses: (\S+)', text):
            self.assertRegex(action, r'^actions/[a-z-]+@[0-9a-f]{40}$')

    def test_schedules_wait_for_the_variable_and_the_default_branch(self):
        text = code(WORKFLOW)
        trigger = text.split('\non:\n', 1)[1].split('\npermissions:', 1)[0]
        self.assertEqual(re.findall(r"cron: '([^']+)'", trigger), ['41 7 * * *'])
        workflow_jobs = jobs(text)
        self.assertEqual(set(workflow_jobs), {'check', 'prepare', 'publish'})
        for name, job in workflow_jobs.items():
            with self.subTest(job=name):
                self.assertRegex(job, r'(?m)^    permissions:\n')
                self.assertIn('runs-on: ubuntu-24.04', job)
        # Only the check runs on the schedule, and only once the variable is set;
        # prepare runs on a dispatch alone, and publish only after it.
        self.assertIn("(github.event_name == 'schedule' && vars.PROVIDER_BUILD_LIST_PUBLISHING == 'true')",
                      ' '.join(workflow_jobs['check'].split('    runs-on:', 1)[0].split()))
        self.assertRegex(workflow_jobs['prepare'].split('    runs-on:', 1)[0], r"github\.event_name == 'workflow_dispatch' &&")
        self.assertNotIn('schedule', workflow_jobs['prepare'] + workflow_jobs['publish'])
        self.assertIn('    needs: prepare\n', workflow_jobs['publish'])
        for name in ('prepare', 'publish'):
            self.assertIn('test "$REF" = "refs/heads/$DEFAULT_BRANCH"', workflow_jobs[name])
        self.assertIn('group: provider-build-list-publication', workflow_jobs['publish'])
        self.assertIn('cancel-in-progress: false', workflow_jobs['publish'])
        self.assertIn('python3 scripts/provider-release-publication.py download', workflow_jobs['publish'])
        self.assertIn('needs.prepare.outputs.artifact_id', workflow_jobs['publish'])
        self.assertIn('needs.prepare.outputs.artifact_digest', workflow_jobs['publish'])
        self.assertIn('needs.prepare.outputs.document_sha256', workflow_jobs['publish'])
        # The escalation opens one issue; its text is the check's neutral message.
        self.assertIn('issues: write', workflow_jobs['check'])
        self.assertIn("if: ${{ failure() && steps.state.outputs.state == 'escalate' }}", workflow_jobs['check'])
        self.assertIn('MESSAGE: ${{ steps.state.outputs.message }}', workflow_jobs['check'])
        self.assertNotIn('issues: write', workflow_jobs['prepare'] + workflow_jobs['publish'])


if __name__ == '__main__':
    unittest.main()
