"""Verify registered release metadata and every public bundle surface."""
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile


def verify_publication(root, env, *, coordinator, core, object_key, download_sha256, bundle_name):
    payload = json.loads((root / 'release-payload.json').read_text())
    latest = coordinator(env, '/v1/releases/latest?platform=macos-arm64')
    is_latest = latest.get('version') == payload['version']
    # Only a strictly newer latest excuses the alias checks. An older latest is
    # evidence that the coordinator kept the previous release.
    superseded = not is_latest and core(latest.get('version') or '0.0.0') > core(payload['version'])

    surfaces = []

    def probe(name, fn):
        # A download or API error is reported as the error, never as a digest mismatch.
        try:
            ok = 'ok' if fn() else 'MISMATCH'
        except Exception as exc:
            ok = f'ERROR ({type(exc).__name__}: {exc})'
        surfaces.append((name, ok))

    if is_latest:
        probe('registration (latest points at this version)',
              lambda: latest.get('bundle_hash') == payload['bundle_hash'])
    elif not superseded:
        probe(f"registration (latest is {latest.get('version')}, not {payload['version']})", lambda: False)
    else:
        print(f"note: latest is {latest.get('version')} (newer than {payload['version']}); "
              f"skipping releases/latest/* alias checks for this release")

    r2_base = env['R2_PUBLIC_URL'].rstrip('/')
    probe('immutable object', lambda: download_sha256(r2_base + '/' + object_key(payload)) == payload['bundle_hash'])

    if is_latest:
        for name in [bundle_name, 'eigeninference-bundle-macos-arm64.tar.gz']:
            surface = 'releases/latest/' + name
            probe(surface, lambda name=name: download_sha256(r2_base + '/releases/latest/' + name) == payload['bundle_hash'])

    if env['ENV_PREFIX'] == 'prod':
        # publish creates the release under the pushed tag (provider_release_github.py).
        tag = env['GITHUB_REF_NAME'] if env.get('GITHUB_REF_TYPE') == 'tag' else 'v' + payload['version']
        repo = env['GITHUB_REPOSITORY']
        state = {}

        def not_a_draft():
            result = subprocess.run(['gh', 'release', 'view', tag, '--repo', repo,
                                      '--json', 'isDraft,assets'], capture_output=True, text=True, check=True)
            state['release'] = json.loads(result.stdout)
            return not state['release']['isDraft']

        probe('github release not a draft', not_a_draft)

        def asset_matches():
            with tempfile.TemporaryDirectory(prefix='verify-release-') as directory:
                subprocess.run(['gh', 'release', 'download', tag, '--repo', repo,
                                 '--pattern', bundle_name, '--dir', directory], check=True)
                with (Path(directory) / bundle_name).open('rb') as stream:
                    digest = hashlib.file_digest(stream, 'sha256').hexdigest()
            return digest == payload['bundle_hash']

        probe('github release asset', asset_matches)

    print('surface -> ok')
    for name, ok in surfaces:
        print(f'{name} -> {ok}')
    failed = [f'{name} ({ok})' for name, ok in surfaces if ok != 'ok']
    if failed:
        raise RuntimeError('verify: surface mismatch: ' + ', '.join(failed))


