"""Download one immutable Actions artifact, checking transport and run identity."""
import json
from pathlib import Path, PurePosixPath
import stat
import subprocess
import tempfile
import unicodedata
import zipfile

import hashlib
import re

BUNDLE = 'darkbloom-bundle-macos-arm64.tar.gz'


def sha256(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def text(value, pattern, label):
    if not isinstance(value, str) or re.fullmatch(pattern, value) is None:
        raise ValueError('Invalid ' + label)


def checked_payload(root, payload_sha256, provenance_sha256, source_commit, signing_run_id):
    """Bind retained metadata and bytes to outputs of the original signing job."""
    for name, expected in [('release-payload.json', payload_sha256),
                           ('release-provenance.json', provenance_sha256)]:
        text(expected, r'[0-9a-f]{64}', 'metadata digest')
        path = root / name
        if path.is_symlink() or sha256(path) != expected:
            raise ValueError('Retained artifact digest mismatch: ' + name)
    payload = json.loads((root / 'release-payload.json').read_bytes())
    provenance = json.loads((root / 'release-provenance.json').read_bytes())
    for record in (payload, provenance):
        run_key = 'ci_run_id' if record is payload else 'signing_run_id'
        if record.get('source_commit') != source_commit or record.get(run_key) != signing_run_id:
            raise ValueError('Retained artifact source/signing run mismatch')
    archive = root / BUNDLE
    if archive.is_symlink() or sha256(archive) != payload['bundle_hash']:
        raise ValueError('Staged signed bundle digest mismatch')
    return payload


def download(repository, artifact_id, artifact_digest, run_id, output):
    text(repository, r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', 'repository')
    text(artifact_id, r'[1-9][0-9]*', 'artifact ID')
    text(run_id, r'[1-9][0-9]*', 'artifact run ID')
    text(artifact_digest, r'(?:sha256:)?[0-9a-f]{64}', 'artifact digest')
    artifact_digest = 'sha256:' + artifact_digest.removeprefix('sha256:')
    api = f'repos/{repository}/actions/artifacts/{artifact_id}'
    metadata = json.loads(subprocess.check_output(['gh', 'api', api], timeout=60))
    if (str(metadata.get('id')) != artifact_id or metadata.get('digest') != artifact_digest or
            metadata.get('expired') is not False or str(metadata.get('workflow_run', {}).get('id')) != run_id):
        raise ValueError('Actions artifact identity, digest, or originating run mismatch')
    if not 0 < metadata.get('size_in_bytes', 0) <= 2 << 30:
        raise ValueError('Actions artifact exceeds size limit')
    with tempfile.TemporaryDirectory() as directory:
        archive = Path(directory) / 'artifact.zip'
        with archive.open('wb') as target:
            # gh handles the authenticated API redirect; no token reaches a blob URL.
            subprocess.run(['gh', 'api', api + '/zip'], stdout=target, check=True, timeout=300)
        if sha256(archive) != artifact_digest.removeprefix('sha256:'):
            raise ValueError('Actions artifact transport digest mismatch')
        with zipfile.ZipFile(archive) as source:
            members = source.infolist()
            names, total = set(), 0
            for member in members:
                name = PurePosixPath(member.filename)
                canonical = unicodedata.normalize('NFC', name.as_posix()).casefold()
                mode = member.external_attr >> 16
                if (name.is_absolute() or '..' in name.parts or '\\' in member.filename or
                        canonical in names or stat.S_ISLNK(mode) or
                        stat.S_IFMT(mode) not in (0, stat.S_IFREG, stat.S_IFDIR)):
                    raise ValueError('Unsafe Actions artifact path')
                names.add(canonical)
                total += member.file_size
                if total > 2 << 30 or len(names) > 16384:
                    raise ValueError('Actions artifact extraction limit exceeded')
            output.mkdir(parents=True, exist_ok=False)
            source.extractall(output)
