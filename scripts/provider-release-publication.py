#!/usr/bin/env python3
"""Stage immutable signed products, then publish the same bytes after approval.

Signing and publication are separate jobs. Rerunning publication never signs or
rebuilds. The release key can request promotion, but cannot grant qualification.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import time
import urllib.error
import urllib.request

from provider_release_github import publish_github_release

BUNDLE = 'darkbloom-bundle-macos-arm64.tar.gz'


class ReadinessPending(RuntimeError):
    pass


def sha256(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def object_key(payload):
    return f"releases/v{payload['version']}/artifacts/{payload['bundle_hash']}/{BUNDLE}"


def validate(payload, env):
    if env["ENV_PREFIX"] not in {"dev", "prod"}:
        raise ValueError("Unknown publication environment")
    expected = {'version': env['VERSION'], 'source_commit': env['GITHUB_SHA'],
                'ci_run_id': env['GITHUB_RUN_ID'], 'platform': 'macos-arm64', 'backend': 'mlx-swift',
                'require_app_attest_qualification': env['ENV_PREFIX'] == 'prod'}
    for key, value in expected.items():
        if payload.get(key) != value:
            raise ValueError(f'Publication identity mismatch: {key}')
    if not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?', payload['version']):
        raise ValueError('Invalid release version')
    for key in ['binary_hash', 'bundle_hash', 'metallib_hash', 'code_directory_hash']:
        if not re.fullmatch('[0-9a-f]{64}', payload.get(key, '')):
            raise ValueError(f'Invalid signed digest: {key}')
    if payload['url'] != env['R2_PUBLIC_URL'].rstrip('/') + '/' + object_key(payload):
        raise ValueError('Publication origin or immutable object path changed')


def release_changelog(env):
    if env.get('GITHUB_REF_TYPE') == 'tag':
        # Read annotation text as data: never interpolate it into Python or a
        # shell program. Preserve multiline notes in the retained JSON payload.
        result = subprocess.run(['git', 'tag', '--list', '--format=%(contents)',
                                 '--', env['GITHUB_REF_NAME']], capture_output=True, text=True, check=True)
        if result.stdout.strip():
            return result.stdout.strip()
    return f"Release v{env['VERSION']}"


def prepare(root, bundle, env):
    root.mkdir(parents=True, exist_ok=False)
    payload = {
        'version': env['VERSION'], 'platform': 'macos-arm64', 'backend': 'mlx-swift',
        'binary_hash': env['BINARY_HASH'], 'bundle_hash': env['BUNDLE_HASH'],
        'metallib_hash': env['METALLIB_HASH'], 'code_directory_hash': env['CODE_DIRECTORY_HASH'],
        'source_commit': env['GITHUB_SHA'], 'ci_run_id': env['GITHUB_RUN_ID'],
        'require_app_attest_qualification': env['ENV_PREFIX'] == 'prod',
        'changelog': release_changelog(env),
    }
    payload['url'] = env['R2_PUBLIC_URL'].rstrip('/') + '/' + object_key(payload)
    validate(payload, env)
    if sha256(bundle) != payload['bundle_hash']:
        raise ValueError('Signed bundle changed after final verification')
    shutil.copyfile(bundle, root / BUNDLE)
    (root / 'release-payload.json').write_text(json.dumps(payload, indent=2) + '\n')
    qualification = {k: payload[k] for k in ['code_directory_hash', 'source_commit', 'ci_run_id']}
    qualification['release'] = {k: v for k, v in payload.items() if k not in qualification and k != 'require_app_attest_qualification'}
    qualification['evidence'] = ''  # Operator supplies actual test evidence, never CI-invented approval.
    (root / 'qualification-request.json').write_text(json.dumps(qualification, indent=2) + '\n')
    notes = f"""## Provider v{payload['version']} (Swift CLI)

**Source:** https://github.com/{env['GITHUB_REPOSITORY']}/commit/{payload['source_commit']}
**Build:** https://github.com/{env['GITHUB_REPOSITORY']}/actions/runs/{payload['ci_run_id']}
**Binary SHA-256:** `{payload['binary_hash']}`
**CodeDirectory SHA-256:** `{payload['code_directory_hash']}`
**Bundle SHA-256:** `{payload['bundle_hash']}`
**Metallib SHA-256:** `{payload['metallib_hash']}`
**Signed and notarized:** yes
**Minimum macOS:** 14.0

### Install

```bash
curl -fsSL {env['COORDINATOR_URL'].rstrip('/')}/install.sh | bash
```
"""
    (root / 'release-notes.md').write_text(notes)
    return payload


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise ValueError('Refusing a redirected coordinator request')


def coordinator(env, path, payload=None):
    headers = {'Accept': 'application/json'}
    data = None
    if payload is not None:
        headers.update({'Content-Type': 'application/json', 'Authorization': 'Bearer ' + env['RELEASE_KEY']})
        data = json.dumps(payload).encode()
    request = urllib.request.Request(env['COORDINATOR_URL'].rstrip('/') + path, data=data, headers=headers)
    try:
        with urllib.request.build_opener(NoRedirect()).open(request, timeout=150) as response:
            return json.load(response)
    except urllib.error.HTTPError as exc:
        if exc.code == 503 and payload is None:
            raise ReadinessPending('Coordinator download policy is still converging') from exc
        if exc.code == 409:
            raise RuntimeError('Publication blocked: approve qualification-request.json with test evidence '
                               'via POST /v1/admin/app-attest/builds, then rerun ONLY the failed publication job. '
                               'Do not rerun signing; it creates different signed bytes.') from exc
        raise RuntimeError(f'Coordinator refused publication/readiness (HTTP {exc.code}); no latest aliases advanced') from exc


def upload(root, key, env):
    subprocess.run(['aws', 's3', 'cp', str(root / BUNDLE), f"s3://{env['R2_BUCKET']}/{key}",
                    '--endpoint-url', env['R2_ENDPOINT'], '--only-show-errors'], check=True)


def checked_payload(root, env):
    payload = json.loads((root / 'release-payload.json').read_text())
    validate(payload, env)
    if sha256(root / BUNDLE) != payload['bundle_hash']:
        raise ValueError('Staged signed bundle digest mismatch')
    return payload


def stage(root, env):
    payload = checked_payload(root, env)
    upload(root, object_key(payload), env)


def await_latest(env, payload):
    # A different coordinator may still have the previous five-second policy
    # snapshot. An older response must not silently skip promotion of this build.
    def core(version):
        match = re.match(r'^(\d+)\.(\d+)\.(\d+)', version)
        if match is None:
            raise ValueError('Malformed latest release version')
        return tuple(int(v) for v in match.groups())
    for attempt in range(7):
        try:
            latest = coordinator(env, '/v1/releases/latest?platform=macos-arm64')
            if latest.get('version') == payload['version']:
                if latest.get('bundle_hash') != payload['bundle_hash']:
                    raise ValueError('Published version contains different signed bytes')
                return True
            if core(latest.get('version', '')) > core(payload['version']):
                return False
        except ReadinessPending:
            # A 503 is expected while another coordinator loads the committed
            # policy. Retry within the same bounded convergence window.
            pass
        if attempt < 6:
            time.sleep(2)
    raise RuntimeError('Latest release readiness has not converged; rerun the publication job')


def publish(root, env):
    payload = checked_payload(root, env)
    coordinator(env, '/v1/releases', payload)
    # Confirm serving policy is active before public aliases/GitHub publication.
    # An older concurrently staged release must never roll latest aliases back.
    is_latest = await_latest(env, payload)
    if is_latest:
        for name in [BUNDLE, 'eigeninference-bundle-macos-arm64.tar.gz']:
            upload(root, 'releases/latest/' + name, env)
    if env['ENV_PREFIX'] == 'prod':
        publish_github_release(root, BUNDLE, payload['bundle_hash'], env, is_latest)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('operation', choices=['prepare', 'stage', 'publish'])
    parser.add_argument('--directory', type=Path, required=True)
    parser.add_argument('--bundle', type=Path)
    args = parser.parse_args()
    if args.operation == 'prepare':
        if args.bundle is None:
            parser.error('prepare requires --bundle')
        prepare(args.directory, args.bundle, os.environ)
    else:
        globals()[args.operation](args.directory, os.environ)


if __name__ == '__main__':
    main()
