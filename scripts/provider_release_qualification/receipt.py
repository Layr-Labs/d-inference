"""Verify complete evidence-bound receipts; never execute candidate code."""
import base64
import json
from pathlib import Path
import subprocess
import tempfile
import urllib.error
import urllib.request

from .contract import decode_envelope, digest, sha256, strict_json, validate_receipt


def verify_evidence(receipt, directory):
    # Evidence is content-addressed, so untrusted reports cannot select paths.
    root = Path(directory)
    for check in receipt['checks']:
        name = digest(check['evidence_sha256'])
        path = root / name
        if path.is_symlink() or sha256(path) != name:
            raise ValueError('Qualification evidence digest mismatch: ' + check['name'])


def verify(envelope, public_key, build, policy, run_id, run_attempt, now=None):
    raw, signature = decode_envelope(envelope)
    try:
        key = base64.b64decode(public_key, validate=True)
        if len(key) != 32:
            raise ValueError('Ed25519 public key must contain 32 bytes')
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            # RFC 8410 SubjectPublicKeyInfo for a raw Ed25519 public key.
            (root / 'key.der').write_bytes(bytes.fromhex('302a300506032b6570032100') + key)
            (root / 'receipt').write_bytes(raw)
            (root / 'signature').write_bytes(signature)
            subprocess.run(['openssl', 'pkeyutl', '-verify', '-pubin', '-keyform', 'DER',
                            '-inkey', str(root / 'key.der'), '-rawin', '-in', str(root / 'receipt'),
                            '-sigfile', str(root / 'signature')], check=True, capture_output=True, timeout=30)
    except (TypeError, ValueError, subprocess.CalledProcessError) as exc:
        raise ValueError('Invalid qualification signature/public key') from exc
    receipt = strict_json(raw)
    validate_receipt(receipt, build, policy, run_id, run_attempt, now)
    return receipt


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise ValueError('Refusing redirected qualification submission')


def submit(envelope, coordinator_url, release_key):
    from urllib.parse import urlsplit
    url = urlsplit(coordinator_url)
    if url.scheme != 'https' or not url.hostname or url.username or url.password or url.query or url.fragment:
        raise ValueError('Qualification coordinator must be an HTTPS origin')
    if not release_key or '\n' in release_key or '\r' in release_key:
        raise ValueError('Missing or invalid release key')
    request = urllib.request.Request(coordinator_url.rstrip('/') + '/v1/releases/qualify',
                                     data=json.dumps(envelope).encode(), method='POST', headers={
                                         'Content-Type': 'application/json', 'Accept': 'application/json',
                                         'Authorization': 'Bearer ' + release_key})
    try:
        with urllib.request.build_opener(NoRedirect()).open(request, timeout=150) as response:
            if response.status != 200:
                raise ValueError('Qualification endpoint did not confirm success')
            return strict_json(response.read(64 * 1024 + 1))
    except urllib.error.HTTPError as exc:
        raise RuntimeError(f'Qualification rejected (HTTP {exc.code}); publication remains blocked') from None
