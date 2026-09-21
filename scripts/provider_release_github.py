"""Resume GitHub release publication without replacing completed assets."""
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile


def publish_github_release(root, bundle_name, expected_hash, env, is_latest):
    tag = env['GITHUB_REF_NAME']
    repo = env['GITHUB_REPOSITORY']

    def gh(*args, **kwargs):
        return subprocess.run(['gh', 'release', *args, '--repo', repo], **kwargs)

    def view(*, required=False):
        result = gh('view', tag, '--json', 'tagName,isDraft,assets', capture_output=True, text=True, check=required)
        if result.returncode != 0:
            return None
        release = json.loads(result.stdout)
        if release['tagName'] != tag:
            raise ValueError('GitHub release tag differs from staged artifact')
        return release

    release = view()
    if release is None:
        # Keep each step recoverable: a failed create/upload/edit can leave a
        # draft or starter asset. A retry re-reads state instead of rebuilding.
        gh('create', tag, '--draft', '--verify-tag', '--title', tag,
           '--notes-file', str(root / 'release-notes.md'), '--generate-notes', check=True)
        release = view(required=True)

    assets = [asset for asset in release['assets'] if asset['name'] == bundle_name]
    if len(assets) > 1:
        raise ValueError('Multiple GitHub release assets have the staged bundle name')
    asset = assets[0] if assets else None
    if asset is None or asset['state'] != 'uploaded':
        if not release['isDraft']:
            raise ValueError('Published GitHub release has no completed bundle; refusing to modify it')
        if asset is not None and asset['state'] != 'starter':
            raise ValueError('Unknown GitHub asset state; refusing replacement')
        # --clobber is limited to an incomplete placeholder on a draft. Never
        # delete/overwrite uploaded bytes, including a mismatched draft asset.
        flags = ['--clobber'] if asset is not None else []
        gh('upload', tag, str(root / bundle_name), *flags, check=True)

    with tempfile.TemporaryDirectory(prefix='verify-published-release-') as directory:
        gh('download', tag, '--pattern', bundle_name, '--dir', directory, check=True)
        with (Path(directory) / bundle_name).open('rb') as stream:
            if hashlib.file_digest(stream, 'sha256').hexdigest() != expected_hash:
                raise ValueError('Existing GitHub release contains different signed bytes; refusing replacement')

    if release['isDraft']:
        gh('edit', tag, '--draft=false', '--verify-tag', '--latest=' + str(is_latest).lower(), check=True)
        if view(required=True)['isDraft']:
            raise RuntimeError('GitHub release is still a draft; rerun the publication job')
