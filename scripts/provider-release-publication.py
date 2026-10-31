#!/usr/bin/env python3
"""Stage immutable signed products, then register and publish the same bytes.

Signing and publication are separate jobs. Rerunning publication never signs or
rebuilds. The coordinator validates the exact build and enforces revocation.
"""
import argparse
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
from provider_release_artifact import BUNDLE, checked_payload as artifact_payload, download, sha256


class ReadinessPending(RuntimeError):
    pass


# The cluster runtime facts (darkbloom_cluster_runtime_v2) of the final signed
# app, written by its own `cluster runtime-facts` (ClusterRuntimeApprovalFacts).
# Any environment's payload may carry the block; the release lane adds it only
# when that environment's *_CLUSTER_RUNTIME_ENABLED variable is 'true'. This
# only checks the block; it computes no digest.
CLUSTER_RUNTIME_SCHEMA = 'darkbloom_cluster_runtime_v2'
CLUSTER_RUNTIME_DIGESTS = ('native_runtime_sha256', 'metallib_sha256', 'resource_library_sha256',
                           'placement_policy_sha256')
CLUSTER_RUNTIME_MODEL_DIGESTS = ('artifact_sha256', 'capability_sha256', 'profile_sha256', 'resource_policy_sha256')
CLUSTER_MODE_FAMILIES = ('hand_off', 'pipeline', 'pipeline_speculative', 'tensor_parallel')
CLUSTER_RUNTIME_MAXIMUM_MODELS = 64
CLUSTER_RUNTIME_MAXIMUM_BYTES = 64 * 1024
# A coordinator derives approvals `release/<version>/<model>/s<1|2>` and, for a
# model with a grant, grants `<approval ID>/grant`, and refuses at registration
# a block with any derived ID over this bound.
CLUSTER_DERIVED_ID_MAXIMUM_BYTES = 128


def is_digest(value):
    return isinstance(value, str) and re.fullmatch('[0-9a-f]{64}', value) is not None and value != '0' * 64


def check_cluster_runtime(block):
    if not isinstance(block, dict) or set(block) != {'schema', 'models', *CLUSTER_RUNTIME_DIGESTS} \
            or block['schema'] != CLUSTER_RUNTIME_SCHEMA:
        raise ValueError('Invalid cluster_runtime: unknown or missing fields or another schema')
    models = block['models']
    if not isinstance(models, list) or not 1 <= len(models) <= CLUSTER_RUNTIME_MAXIMUM_MODELS:
        raise ValueError(f'Invalid cluster_runtime: 1 to {CLUSTER_RUNTIME_MAXIMUM_MODELS} models are required')
    digests, names = [block[key] for key in CLUSTER_RUNTIME_DIGESTS], []
    for model in models:
        if not isinstance(model, dict) or set(model) != {'model', 'pair_serving_grant', *CLUSTER_RUNTIME_MODEL_DIGESTS}:
            raise ValueError('Invalid cluster_runtime: unknown or missing model fields')
        if not isinstance(model['model'], str) or re.fullmatch(r'[\x20-\x7e]{1,128}', model['model']) is None:
            raise ValueError('Invalid cluster_runtime: a model ID is not 1 to 128 printable ASCII bytes')
        names.append(model['model'].encode())
        digests += [model[key] for key in CLUSTER_RUNTIME_MODEL_DIGESTS]
        grant = model['pair_serving_grant']
        if grant is None:
            continue
        if not isinstance(grant, dict) or set(grant) != {'evidence_sha256', 'mode_families'}:
            raise ValueError('Invalid cluster_runtime: a pair_serving_grant is not null or exactly '
                             'evidence_sha256 and mode_families')
        families = grant['mode_families']
        if not isinstance(families, list) or not families \
                or any(not isinstance(family, str) or family not in CLUSTER_MODE_FAMILIES for family in families) \
                or any(first >= second for first, second in zip(families, families[1:])):
            raise ValueError('Invalid cluster_runtime: mode_families must list 1 to 4 known mode families, '
                             'sorted by byte and unique')
        digests.append(grant['evidence_sha256'])
    if not all(is_digest(value) for value in digests):
        raise ValueError('Invalid cluster_runtime: a digest is not 64 lowercase hex characters or is zero')
    if any(first >= second for first, second in zip(names, names[1:])):
        raise ValueError('Invalid cluster_runtime: models must be sorted by model ID and unique')


def check_cluster_derived_ids(block, version):
    """Every ID a coordinator derives from the block fits its bound."""
    for model in block['models']:
        longest = f"release/{version}/{model['model']}/s2" + ('' if model['pair_serving_grant'] is None else '/grant')
        if len(longest.encode()) > CLUSTER_DERIVED_ID_MAXIMUM_BYTES:
            raise ValueError(f'Invalid cluster_runtime: a derived cluster approval or grant ID exceeds '
                             f'{CLUSTER_DERIVED_ID_MAXIMUM_BYTES} bytes')


def load_cluster_runtime(path):
    data = Path(path).read_bytes()
    if len(data) > CLUSTER_RUNTIME_MAXIMUM_BYTES:
        raise ValueError('Invalid cluster_runtime: the block exceeds its bound')

    def unique(pairs):
        if len({key for key, _ in pairs}) != len(pairs):
            raise ValueError('Invalid cluster_runtime: a field is repeated')
        return dict(pairs)
    try:
        block = json.loads(data, object_pairs_hook=unique)
    except json.JSONDecodeError as error:
        raise ValueError('Invalid cluster_runtime: not JSON') from error
    check_cluster_runtime(block)
    return block


def object_key(payload):
    return f"releases/v{payload['version']}/artifacts/{payload['bundle_hash']}/{BUNDLE}"


def release_source(env):
    source = env.get('RELEASE_SOURCE_SHA') or env['GITHUB_SHA']
    if not re.fullmatch(r'[0-9a-f]{40}', source):
        raise ValueError('Invalid release source commit')
    return source


def validate(payload, env):
    if env["ENV_PREFIX"] not in {"dev", "prod"}:
        raise ValueError("Unknown publication environment")
    expected = {'version': env['VERSION'], 'source_commit': release_source(env),
                'ci_run_id': env.get('RELEASE_SIGNING_RUN_ID') or env['GITHUB_RUN_ID'], 'platform': 'macos-arm64', 'backend': 'mlx-swift',
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
    if 'cluster_runtime' in payload:
        check_cluster_runtime(payload['cluster_runtime'])
        check_cluster_derived_ids(payload['cluster_runtime'], payload['version'])


def release_changelog(env):
    if env.get('RELEASE_TAG') or env.get('GITHUB_REF_TYPE') == 'tag':
        # Read annotation text as data: never interpolate it into Python or a
        # shell program. Preserve multiline notes in the retained JSON payload.
        # Git identifies the signature suffix separately. Keep the original
        # contents as bytes so paragraph spacing and CRLFs are not reformatted.
        result = subprocess.run(['git', 'tag', '--list', '--format=%(contents)%00%(contents:signature)%00',
                                 '--', env.get('RELEASE_TAG') or env['GITHUB_REF_NAME']], capture_output=True, check=True)
        if result.stdout:
            contents, signature, _ = result.stdout.split(b'\0', 2)
            notes = contents.removesuffix(signature).decode('utf-8').strip()
            if notes:
                return notes
    return f"Release v{env['VERSION']}"


def prepare(root, bundle, env, cluster_runtime=None):
    # Read before anything is written: a refused block leaves no publication folder.
    block = None if cluster_runtime is None else load_cluster_runtime(cluster_runtime)
    root.mkdir(parents=True, exist_ok=False)
    payload = {
        'version': env['VERSION'], 'platform': 'macos-arm64', 'backend': 'mlx-swift',
        'binary_hash': env['BINARY_HASH'], 'bundle_hash': env['BUNDLE_HASH'],
        'metallib_hash': env['METALLIB_HASH'], 'code_directory_hash': env['CODE_DIRECTORY_HASH'],
        'source_commit': release_source(env), 'ci_run_id': env['GITHUB_RUN_ID'],
        # Shipped wire name: require complete native identity, not a hardware test.
        'require_app_attest_qualification': env['ENV_PREFIX'] == 'prod',
        'changelog': release_changelog(env),
    }
    payload['url'] = env['R2_PUBLIC_URL'].rstrip('/') + '/' + object_key(payload)
    if block is not None:
        payload['cluster_runtime'] = block
    validate(payload, env)
    if sha256(bundle) != payload['bundle_hash']:
        raise ValueError('Signed bundle changed after final verification')
    shutil.copyfile(bundle, root / BUNDLE)
    provenance = {'source_commit': release_source(env), 'signing_workflow_commit': env['GITHUB_SHA'],
                  'signing_run_id': env['GITHUB_RUN_ID'],
                  'signing_run_attempt': env.get('GITHUB_RUN_ATTEMPT', '1'),
                  'build_run_id': env.get('RELEASE_BUILD_RUN_ID') or env['GITHUB_RUN_ID'],
                  'build_run_attempt': env.get('RELEASE_BUILD_RUN_ATTEMPT') or env.get('GITHUB_RUN_ATTEMPT', '1'),
                  'unsigned_artifact_id': env.get('RELEASE_UNSIGNED_ARTIFACT_ID', ''),
                  'unsigned_artifact_digest': env.get('RELEASE_UNSIGNED_ARTIFACT_DIGEST', '')}
    (root / 'release-provenance.json').write_text(json.dumps(provenance, indent=2) + '\n')
    (root / 'release-payload.json').write_text(json.dumps(payload, indent=2) + '\n')
    notes = f"""## Provider v{payload['version']} (Swift CLI)

**Source:** https://github.com/{env['GITHUB_REPOSITORY']}/commit/{payload['source_commit']}
**Build and SDK qualification:** https://github.com/{env['GITHUB_REPOSITORY']}/actions/runs/{provenance['build_run_id']}
**Signing:** https://github.com/{env['GITHUB_REPOSITORY']}/actions/runs/{payload['ci_run_id']}
**Binary SHA-256:** `{payload['binary_hash']}`
**CodeDirectory SHA-256:** `{payload['code_directory_hash']}`
**Bundle SHA-256:** `{payload['bundle_hash']}`
**Metallib SHA-256:** `{payload['metallib_hash']}`
**Signed and notarized:** yes
**macOS deployment target:** 14.0 (build, tests and signed runtime smoke: macOS 27)

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
            raise RuntimeError('Publication blocked: conflicting release identity or revoked artifact; '
                               'no latest aliases advanced. Resolve the conflict or revocation before '
                               'retrying the same retained artifact. Do not rerun signing; '
                               'it creates different signed bytes.') from exc
        raise RuntimeError(f'Coordinator refused publication/readiness (HTTP {exc.code}); no latest aliases advanced') from exc


def upload(root, key, env):
    subprocess.run(['aws', 's3', 'cp', str(root / BUNDLE), f"s3://{env['R2_BUCKET']}/{key}",
                    '--endpoint-url', env['R2_ENDPOINT'], '--only-show-errors'], check=True)


def checked_payload(root, env):
    payload = artifact_payload(root, env['RELEASE_PAYLOAD_SHA256'], env['RELEASE_PROVENANCE_SHA256'],
                               release_source(env), env.get('RELEASE_SIGNING_RUN_ID') or env['GITHUB_RUN_ID'])
    validate(payload, env)
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
    if env['ENV_PREFIX'] == 'prod':
        from provider_release_resume.api import GitHub, verify_source, verify_tag
        tag = env.get('RELEASE_TAG') or env.get('GITHUB_REF_NAME')
        if tag != 'v' + payload['version']:
            raise ValueError('Publication tag and version differ')
        api = GitHub(env['GITHUB_REPOSITORY'])
        verify_tag(api, tag, payload['source_commit'])
        verify_source(api, payload['source_commit'])
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
    parser.add_argument('operation', choices=['prepare', 'download', 'stage', 'publish'])
    parser.add_argument('--directory', type=Path, required=True)
    parser.add_argument('--bundle', type=Path)
    parser.add_argument('--artifact-id')
    parser.add_argument('--artifact-digest')
    parser.add_argument('--run-id')
    parser.add_argument('--cluster-runtime', type=Path,
                        help='prepare: the cluster runtime facts of the final signed app, sent as cluster_runtime')
    args = parser.parse_args()
    if args.cluster_runtime is not None and args.operation != 'prepare':
        parser.error('--cluster-runtime is a prepare option')
    if args.operation == 'download':
        download(os.environ['GITHUB_REPOSITORY'], args.artifact_id, args.artifact_digest,
                 args.run_id, args.directory)
    elif args.operation == 'prepare':
        if args.bundle is None:
            parser.error('prepare requires --bundle')
        prepare(args.directory, args.bundle, os.environ, args.cluster_runtime)
    else:
        globals()[args.operation](args.directory, os.environ)


if __name__ == '__main__':
    main()
